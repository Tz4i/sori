import AudioToolbox
import Foundation
import Observation
import OSLog

/// Owns the per-app volume state for one bundle identifier: the remembered
/// slider position, mute state, and (lazily) the `ProcessAudioTapEngine`
/// actually applying it. A tap only exists while the effective gain is not
/// 1.0 - there's no reason to tap an app the user hasn't touched.
@MainActor
@Observable
final class AppVolumeController {
    private let logger: Logger

    let bundleIdentifier: String

    /// The slider's remembered position - what unmuting restores to. Always
    /// clamped to 0.0...2.0. This is what gets persisted, independent of
    /// mute state.
    private(set) var sliderGain: Float
    private(set) var isMuted: Bool = false

    /// The gain actually being applied right now (0 while muted).
    var effectiveGain: Float { isMuted ? 0.0 : sliderGain }

    /// This app's "Redirect Audio To" choice, by device UID - `nil` means
    /// "No Redirect" (follow whatever the tap would otherwise target, i.e.
    /// the default system output device). Kept as a UID, not a live
    /// AudioObjectID, for the same reason gain/mute persist by bundle
    /// identifier rather than pid: it has to survive relaunches and device
    /// reconnects where the underlying AudioObjectID changes.
    private(set) var redirectDeviceUID: String?
    /// Best-known display name for `redirectDeviceUID`, persisted alongside
    /// it - used to show *something* meaningful in the picker when the
    /// device is temporarily disconnected (`isRedirectPending`), instead of
    /// silently falling back to "No Redirect" and looking like the user's
    /// choice was cleared.
    private(set) var redirectDeviceDisplayName: String?

    private let availableDevices: AvailableAudioDevices

    /// The UID's currently-connected `AudioObjectID`, or `nil` if there's no
    /// redirect preference OR the preferred device isn't connected right
    /// now. This `nil`-on-disconnect resolution is what makes "fall back to
    /// system output when the target device disappears" happen for free:
    /// with no resolvable device, `needsTap`/`rebuildTap` fall through to
    /// exactly the same path as "No Redirect".
    private var effectiveRedirectDeviceID: AudioObjectID? {
        guard let redirectDeviceUID else { return nil }
        return availableDevices.outputDeviceID(forUID: redirectDeviceUID)
    }

    /// True when the user has a redirect preference set but its device isn't
    /// currently connected - lets the UI show "(unavailable)" rather than
    /// implying the preference was silently cleared.
    var isRedirectPending: Bool {
        redirectDeviceUID != nil && effectiveRedirectDeviceID == nil
    }

    /// A tap is needed whenever gain/mute isn't a no-op OR there's an
    /// actually-resolvable redirect target - a pending-but-disconnected
    /// redirect at gain 1.0/unmuted needs no tap, same as no redirect at all.
    private var needsTap: Bool { effectiveGain != 1.0 || effectiveRedirectDeviceID != nil }

    @ObservationIgnored
    private var pids: Set<pid_t> = []
    @ObservationIgnored
    private var tapEngine: ProcessAudioTapEngine?
    /// The redirect target actually baked into the currently-running
    /// `tapEngine`'s aggregate (`nil` if no tap, or a tap with no redirect).
    /// Distinct from `effectiveRedirectDeviceID`, which is always a fresh
    /// live computation - this is "what did we last actually build," so
    /// `refreshTapForRedirectChange` can tell a genuine target change from a
    /// notification that fired for an unrelated reason and skip rebuilding
    /// when nothing this controller cares about actually changed.
    @ObservationIgnored
    private var appliedRedirectDeviceID: AudioObjectID?

    /// Rebuild-loop guard: defense-in-depth against a future regression
    /// reintroducing runaway rebuilds (this app hit exactly that live - see
    /// CLAUDE.md). If this app's tap rebuilds more than
    /// `rebuildLoopThreshold` times within `rebuildLoopWindow` seconds,
    /// further automatic rebuilds are suppressed and a loud warning is
    /// logged, so a regression shows up as a log line instead of cycling
    /// audio. Cleared on the next explicit user interaction (slider, mute,
    /// or redirect picker), since a deliberate user action deserves a clean
    /// slate rather than staying stuck silent because of an unrelated past
    /// loop.
    @ObservationIgnored
    private var recentRebuildTimestamps: [CFAbsoluteTime] = []
    @ObservationIgnored
    private var rebuildLoopGuardTripped = false
    private static let rebuildLoopThreshold = 5
    private static let rebuildLoopWindow: CFAbsoluteTime = 10

    /// Debounced-teardown timer: when gain lands on exactly unity (1.0),
    /// unmuted, with no redirect - the "no tap needed" state - the tap is
    /// deliberately NOT torn down immediately. It's kept alive at gain 1.0
    /// (a unity-gain tap passes audio through unmodified; costs a little
    /// CPU, audibly nothing) and this timer is scheduled to actually tear
    /// it down after `unityTeardownDebounce` seconds of staying there. If
    /// gain moves off unity again before it fires, `applyGain()` cancels it
    /// and the tap just keeps running at the new gain - no teardown, no
    /// rebuild. Exists because a live slider drag oscillating across the
    /// ±4% "snap to 100%" zone (`snappingGain` in SoriApp.swift) used to
    /// tear the tap down and immediately rebuild it on every single
    /// crossing - confirmed live at ~25/sec during a simulated fast
    /// back-and-forth drag, every single one starting from a cold tap
    /// (`hadRunningTap=false`), which is what produced the reported popping
    /// and "audio stops entirely" - the tap essentially never survived long
    /// enough to pass coherent audio. `performDebouncedTeardown` re-checks
    /// `needsTap` at fire time (not just at schedule time), so even a path
    /// that doesn't explicitly cancel this timer (redirect changes, system
    /// default output changes) can't tear down a tap that's needed again by
    /// the time the debounce elapses.
    @ObservationIgnored
    private var unityTeardownTimer: Timer?
    private static let unityTeardownDebounce: TimeInterval = 1.5

    /// Permanently true for the rest of this session once the user has
    /// touched this app's slider or mute button at all - regardless of
    /// whether the resulting value is back at default. A *time-limited*
    /// grace period here was the wrong call (confirmed live): it made a row
    /// vanish a few seconds after the user set it to exactly 100% and walked
    /// away, which looked identical to "disappears when I touch the
    /// slider" since that was the last thing they did before the grace
    /// window quietly expired. Once touched, an app stays listed for the
    /// rest of the session, same as one that's ever actually played audio.
    private(set) var hasBeenInteractedWith = false

    init(bundleIdentifier: String, availableDevices: AvailableAudioDevices) {
        self.bundleIdentifier = bundleIdentifier
        self.availableDevices = availableDevices
        self.logger = Logger(subsystem: "com.sebastianzapata.sori", category: "AppVolumeController(\(bundleIdentifier))")
        self.sliderGain = Self.loadPersistedGain(for: bundleIdentifier) ?? 1.0
        self.isMuted = Self.loadPersistedMuted(for: bundleIdentifier)
        self.redirectDeviceUID = Self.loadPersistedRedirectDeviceUID(for: bundleIdentifier)
        self.redirectDeviceDisplayName = Self.loadPersistedRedirectDeviceName(for: bundleIdentifier)
    }

    deinit {
        tapEngine?.stop()
    }

    func setSlider(_ value: Float) {
        hasBeenInteractedWith = true
        resetRebuildLoopGuard()
        let clamped = min(max(value, 0.0), 2.0)
        guard clamped != sliderGain else { return }
        sliderGain = clamped
        Self.persistGain(clamped, for: bundleIdentifier)
        if !isMuted { applyGain() }
    }

    func toggleMute() {
        hasBeenInteractedWith = true
        resetRebuildLoopGuard()
        isMuted.toggle()
        Self.persistMuted(isMuted, for: bundleIdentifier)
        applyGain()
    }

    /// Sets this app's "Redirect Audio To" target. `uid: nil` means "No
    /// Redirect". `name` is the device's current display name, persisted
    /// alongside the UID purely so `redirectDeviceDisplayName` has something
    /// to show if the device is disconnected next time this app appears.
    /// Always goes through a full tap teardown/rebuild - the output device
    /// is baked into the aggregate at creation time and can't be changed on
    /// a live tap, unlike gain, which just updates in place.
    func setRedirectDevice(uid: String?, name: String?) {
        hasBeenInteractedWith = true
        resetRebuildLoopGuard()
        guard uid != redirectDeviceUID else { return }
        SoriDebugLog.log("[\(bundleIdentifier)] setRedirectDevice: \(redirectDeviceUID ?? "nil") -> \(uid ?? "nil")")
        redirectDeviceUID = uid
        redirectDeviceDisplayName = uid == nil ? nil : name
        Self.persistRedirectDevice(uid: uid, name: name, for: bundleIdentifier)
        refreshTapForRedirectChange()
    }

    /// Called whenever this app's *effective* redirect target may have
    /// changed without the user touching this app's own picker - i.e. when
    /// `AvailableAudioDevices` announces the device list changed (the
    /// target device was plugged in or unplugged). Compares against
    /// `appliedRedirectDeviceID` - what's actually baked into the live
    /// tap right now - and is a no-op unless that specific value actually
    /// changed. This must stay strict: this exact call, made unconditional,
    /// is what caused a confirmed-live self-sustaining rebuild loop (every
    /// device-list notification, including ones caused by this app's own
    /// tap rebuilding, triggered another rebuild). See CLAUDE.md.
    func refreshTapForRedirectChange() {
        let newTarget = effectiveRedirectDeviceID
        guard newTarget != appliedRedirectDeviceID else {
            SoriDebugLog.log("[\(bundleIdentifier)] refreshTapForRedirectChange: target unchanged (\(newTarget.map(String.init) ?? "nil")) - no-op")
            return
        }
        // Distinguish the two hot-plug directions in the log, not just
        // "redirect target changed" - this is the signal used to confirm
        // live that a disconnect falls back and a reconnect restores.
        let reason: String
        if newTarget == nil {
            reason = "redirect target disconnected, falling back to system output"
        } else if appliedRedirectDeviceID == nil {
            reason = "redirect target (re)connected, restoring redirect"
        } else {
            reason = "redirect target changed"
        }
        SoriDebugLog.log("[\(bundleIdentifier)] refreshTapForRedirectChange: target \(appliedRedirectDeviceID.map(String.init) ?? "nil") -> \(newTarget.map(String.init) ?? "nil") (\(reason)), needsTap=\(needsTap) pids=\(pids.sorted())")
        guard needsTap else {
            teardownTap()
            return
        }
        guard !pids.isEmpty else { return }
        rebuildTap(gain: effectiveGain, reason: reason)
    }

    /// Called when the system's *default* OUTPUT device itself changes
    /// (`kAudioHardwarePropertyDefaultSystemOutputDevice`, trap #17 - NOT
    /// `kAudioHardwarePropertyDefaultOutputDevice`) - distinct from
    /// `refreshTapForRedirectChange()`, which reacts to the AVAILABLE
    /// DEVICE LIST changing (hot-plug) and only ever moves a tap that has
    /// an explicit redirect target. An app with NO redirect
    /// (`redirectDeviceUID == nil`) has its aggregate's output baked in at
    /// CREATION time to whatever the system default was then
    /// (`ProcessAudioTapEngine.createAggregateDevice` falls back to
    /// `kAudioHardwarePropertyDefaultSystemOutputDevice` when
    /// `outputDeviceOverride` is nil) - it never re-reads that default on
    /// its own, so without this, a tapped app keeps rendering to the OLD
    /// device forever after the user switches outputs mid-session, while
    /// every untapped app correctly follows the new default for free (real
    /// Core Audio routing, no Sori involvement needed).
    ///
    /// Deliberately a no-op for any app WITH an explicit redirect - staying
    /// on the chosen device regardless of what the system default does is
    /// the entire point of a redirect. Also a no-op with no live tap
    /// (`tapEngine == nil`): an app at gain 1.0/unmuted/no-redirect has
    /// nothing baked in to be stale.
    func refreshTapForSystemDefaultOutputChange() {
        guard redirectDeviceUID == nil else {
            SoriDebugLog.log("[\(bundleIdentifier)] refreshTapForSystemDefaultOutputChange: has explicit redirect (\(redirectDeviceUID ?? "?")) - not moving")
            return
        }
        guard tapEngine != nil else {
            SoriDebugLog.log("[\(bundleIdentifier)] refreshTapForSystemDefaultOutputChange: no live tap - nothing to rebuild")
            return
        }
        SoriDebugLog.log("[\(bundleIdentifier)] refreshTapForSystemDefaultOutputChange: system default output changed, rebuilding (no redirect, pids=\(pids.sorted()))")
        rebuildTap(gain: effectiveGain, reason: "system default output device changed")
    }

    /// Called every monitor refresh with this app's current set of
    /// audio-producing PIDs. If a tap is already active (or should become
    /// active) and the PID set changed - a tab/helper opened or closed -
    /// the tap is rebuilt to target the new set.
    func updatePIDs(_ newPids: Set<pid_t>) {
        guard newPids != pids else {
            if SoriDebugLog.isEnabled, !newPids.isEmpty {
                SoriDebugLog.log("[\(bundleIdentifier)] updatePIDs: unchanged (\(newPids.sorted())) - no-op")
            }
            return
        }

        SoriDebugLog.log("[\(bundleIdentifier)] updatePIDs: \(pids.sorted()) -> \(newPids.sorted())")
        pids = newPids

        guard needsTap else { return }

        if pids.isEmpty {
            teardownTap()
        } else {
            rebuildTap(gain: effectiveGain, reason: "pid set changed")
        }
    }

    private func applyGain() {
        let target = effectiveGain
        SoriDebugLog.log("[\(bundleIdentifier)] applyGain: target=\(target) effectiveRedirectDeviceID=\(effectiveRedirectDeviceID.map(String.init) ?? "nil") hasLiveTap=\(tapEngine != nil)")
        if target == 1.0 && effectiveRedirectDeviceID == nil {
            if let tapEngine {
                // Don't tear down immediately - keep passing audio through
                // at unity gain and only actually destroy the tap if this
                // holds for `unityTeardownDebounce` seconds. See
                // `unityTeardownTimer`'s doc comment for why.
                tapEngine.gain = target
                scheduleUnityTeardownIfNeeded()
            }
            // else: no live tap and none needed - already correctly absent.
        } else if let tapEngine {
            // Gain alone can be updated on a live tap - only the output
            // device is fixed at creation time and needs a full rebuild.
            cancelPendingUnityTeardown()
            tapEngine.gain = target
        } else {
            cancelPendingUnityTeardown()
            rebuildTap(gain: target, reason: "gain/mute changed")
        }
    }

    /// Schedules (or re-schedules) the debounced teardown - see
    /// `unityTeardownTimer`'s doc comment. Not `RunLoop.main.add(_:forMode:)`
    /// via `Timer.scheduledTimer`, since that only fires in the `.default`
    /// run loop mode - `.common` keeps it firing even while a menu (the
    /// redirect picker, the gear menu) is open, same reasoning as
    /// `AudioProcessMonitor`'s poll timer.
    private func scheduleUnityTeardownIfNeeded() {
        guard !needsTap, tapEngine != nil else { return }
        unityTeardownTimer?.invalidate()
        let t = Timer(timeInterval: Self.unityTeardownDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.performDebouncedTeardown() }
        }
        RunLoop.main.add(t, forMode: .common)
        unityTeardownTimer = t
        SoriDebugLog.log("[\(bundleIdentifier)] scheduleUnityTeardownIfNeeded: tap kept alive at unity gain, teardown in \(Self.unityTeardownDebounce)s unless gain moves again")
    }

    /// Called whenever gain moves off unity (or a redirect/mute makes a tap
    /// needed again) - cancels a pending debounced teardown so the tap just
    /// keeps running. Not strictly required for correctness on every path
    /// (`performDebouncedTeardown` re-checks `needsTap` at fire time
    /// regardless), but avoids a stray timer firing uselessly later on the
    /// most common path (the user moving the slider again).
    private func cancelPendingUnityTeardown() {
        guard unityTeardownTimer != nil else { return }
        unityTeardownTimer?.invalidate()
        unityTeardownTimer = nil
        SoriDebugLog.log("[\(bundleIdentifier)] cancelPendingUnityTeardown: gain moved again before debounce fired")
    }

    private func performDebouncedTeardown() {
        unityTeardownTimer = nil
        guard !needsTap else {
            SoriDebugLog.log("[\(bundleIdentifier)] performDebouncedTeardown: needsTap became true again - skip")
            return
        }
        SoriDebugLog.log("[\(bundleIdentifier)] performDebouncedTeardown: still at unity/no redirect after \(Self.unityTeardownDebounce)s - tearing down")
        teardownTap()
    }

    /// Resets the rebuild-loop guard - called on every explicit user
    /// interaction (slider, mute, redirect picker), since a fresh manual
    /// action deserves a clean slate rather than staying stuck silent
    /// because of an unrelated past loop.
    private func resetRebuildLoopGuard() {
        recentRebuildTimestamps.removeAll()
        rebuildLoopGuardTripped = false
    }

    private func rebuildTap(gain: Float, reason: String) {
        guard !rebuildLoopGuardTripped else {
            SoriDebugLog.log("[\(bundleIdentifier)] rebuildTap SKIPPED - loop guard tripped (reason=\(reason))")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        recentRebuildTimestamps.append(now)
        recentRebuildTimestamps.removeAll { now - $0 > Self.rebuildLoopWindow }
        if recentRebuildTimestamps.count > Self.rebuildLoopThreshold {
            rebuildLoopGuardTripped = true
            logger.fault("Tap rebuild loop detected: \(self.recentRebuildTimestamps.count, privacy: .public) rebuilds in \(Self.rebuildLoopWindow, privacy: .public)s (last reason=\(reason, privacy: .public)) - suppressing further automatic rebuilds")
            SoriDebugLog.log("[\(bundleIdentifier)] *** REBUILD LOOP DETECTED *** \(recentRebuildTimestamps.count) rebuilds in \(Self.rebuildLoopWindow)s, last reason=\(reason) - suppressing further rebuilds until next user interaction")
            teardownTap()
            return
        }

        // Measure and log the silent gap only when there was actually a
        // running tap to interrupt - starting a tap from cold (nothing to
        // interrupt) isn't a "gap."
        let hadRunningTap = tapEngine != nil
        let rebuildStartedAt = hadRunningTap ? CFAbsoluteTimeGetCurrent() : nil
        SoriDebugLog.log("[\(bundleIdentifier)] rebuildTap called: reason=\(reason) gain=\(gain) pids=\(pids.sorted()) hadRunningTap=\(hadRunningTap) redirect=\(effectiveRedirectDeviceID.map(String.init) ?? "nil")")

        teardownTap()
        guard !pids.isEmpty else { return }

        let targetObjectIDs = pids.compactMap { try? AudioObjectID.translatePIDToProcessObjectID(pid: $0) }
        guard !targetObjectIDs.isEmpty else {
            logger.warning("No valid process objects among \(self.pids.count, privacy: .public) pid(s); not starting a tap")
            SoriDebugLog.log("[\(bundleIdentifier)] rebuildTap: no valid process objects among \(pids.sorted()) - not starting")
            return
        }

        let redirectTarget = effectiveRedirectDeviceID
        let engine = ProcessAudioTapEngine(target: .only(targetObjectIDs), gain: gain, outputDevice: redirectTarget)
        do {
            try engine.start()
            tapEngine = engine
            appliedRedirectDeviceID = redirectTarget
            if let rebuildStartedAt {
                let gapMs = (CFAbsoluteTimeGetCurrent() - rebuildStartedAt) * 1000
                logger.notice("Tap rebuilt in \(String(format: "%.1f", gapMs), privacy: .public)ms")
                SoriDebugLog.log("[\(bundleIdentifier)] rebuildTap: gap was \(String(format: "%.1f", gapMs))ms")
            }
            logger.notice("Tap started: \(targetObjectIDs.count, privacy: .public) pid(s), gain=\(gain, privacy: .public), redirect=\(redirectTarget.map(String.init) ?? "none", privacy: .public)")
            SoriDebugLog.log("[\(bundleIdentifier)] rebuildTap: started ok, \(targetObjectIDs.count) pid(s), gain=\(gain), redirect=\(redirectTarget.map(String.init) ?? "none")")
        } catch {
            logger.error("Failed to start tap: \(String(describing: error), privacy: .public)")
            SoriDebugLog.log("[\(bundleIdentifier)] rebuildTap: FAILED to start: \(error)")
        }
    }

    private func teardownTap() {
        // Defensive cleanup regardless of entry path (the rebuild-loop
        // guard and `refreshTapForRedirectChange` can both reach this
        // directly, not just the debounce firing itself) - a stale pending
        // timer left after some OTHER teardown path would otherwise fire
        // later and attempt a redundant (harmless, but sloppy) re-teardown.
        unityTeardownTimer?.invalidate()
        unityTeardownTimer = nil
        guard tapEngine != nil else { return }
        SoriDebugLog.log("[\(bundleIdentifier)] teardownTap called")
        tapEngine?.stop()
        tapEngine = nil
        appliedRedirectDeviceID = nil
        logger.notice("Tap stopped (gain back to 1.0 or no active pids)")
    }

    // MARK: - Persistence

    private static let gainKeyPrefix = "com.sebastianzapata.sori.gain."
    private static let mutedKeyPrefix = "com.sebastianzapata.sori.muted."
    private static let redirectUIDKeyPrefix = "com.sebastianzapata.sori.redirectUID."
    private static let redirectNameKeyPrefix = "com.sebastianzapata.sori.redirectName."

    private static func gainDefaultsKey(for bundleIdentifier: String) -> String {
        gainKeyPrefix + bundleIdentifier
    }

    private static func mutedDefaultsKey(for bundleIdentifier: String) -> String {
        mutedKeyPrefix + bundleIdentifier
    }

    private static func redirectUIDDefaultsKey(for bundleIdentifier: String) -> String {
        redirectUIDKeyPrefix + bundleIdentifier
    }

    private static func redirectNameDefaultsKey(for bundleIdentifier: String) -> String {
        redirectNameKeyPrefix + bundleIdentifier
    }

    private static func loadPersistedGain(for bundleIdentifier: String) -> Float? {
        let key = gainDefaultsKey(for: bundleIdentifier)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.float(forKey: key)
    }

    private static func persistGain(_ value: Float, for bundleIdentifier: String) {
        UserDefaults.standard.set(value, forKey: gainDefaultsKey(for: bundleIdentifier))
        cachedPinnedBundleIdentifiers = nil
    }

    private static func loadPersistedMuted(for bundleIdentifier: String) -> Bool {
        UserDefaults.standard.bool(forKey: mutedDefaultsKey(for: bundleIdentifier))
    }

    private static func persistMuted(_ value: Bool, for bundleIdentifier: String) {
        UserDefaults.standard.set(value, forKey: mutedDefaultsKey(for: bundleIdentifier))
        cachedPinnedBundleIdentifiers = nil
    }

    private static func loadPersistedRedirectDeviceUID(for bundleIdentifier: String) -> String? {
        UserDefaults.standard.string(forKey: redirectUIDDefaultsKey(for: bundleIdentifier))
    }

    private static func loadPersistedRedirectDeviceName(for bundleIdentifier: String) -> String? {
        UserDefaults.standard.string(forKey: redirectNameDefaultsKey(for: bundleIdentifier))
    }

    private static func persistRedirectDevice(uid: String?, name: String?, for bundleIdentifier: String) {
        let uidKey = redirectUIDDefaultsKey(for: bundleIdentifier)
        let nameKey = redirectNameDefaultsKey(for: bundleIdentifier)
        if let uid {
            UserDefaults.standard.set(uid, forKey: uidKey)
            if let name {
                UserDefaults.standard.set(name, forKey: nameKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: uidKey)
            UserDefaults.standard.removeObject(forKey: nameKey)
        }
        cachedPinnedBundleIdentifiers = nil
    }

    /// Cache for `pinnedBundleIdentifiers()`, called from
    /// `AudioProcessMonitor.refresh()` on every poll tick (4x/sec at the
    /// current 250ms interval). The underlying persisted state only actually
    /// changes on an explicit user interaction (slider/mute/redirect), so
    /// recomputing it by merging every key in
    /// `UserDefaults.standard.dictionaryRepresentation()` (hundreds of keys,
    /// almost all unrelated to Sori) on every tick was pure waste.
    /// Invalidated by `persistGain`/`persistMuted`/`persistRedirectDevice` -
    /// the only three places the underlying keys change.
    private static var cachedPinnedBundleIdentifiers: Set<String>?

    /// Bundle identifiers with a persisted, non-default setting (gain != 1.0,
    /// muted, or a redirect target set) - used by `AudioProcessMonitor` to
    /// keep an app "pinned" in the list even while it's not currently
    /// producing audio.
    static func pinnedBundleIdentifiers() -> Set<String> {
        if let cachedPinnedBundleIdentifiers {
            return cachedPinnedBundleIdentifiers
        }

        var result = Set<String>()

        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            if key.hasPrefix(gainKeyPrefix) {
                if let number = value as? NSNumber, number.floatValue != 1.0 {
                    result.insert(String(key.dropFirst(gainKeyPrefix.count)))
                }
            } else if key.hasPrefix(mutedKeyPrefix) {
                if let number = value as? NSNumber, number.boolValue {
                    result.insert(String(key.dropFirst(mutedKeyPrefix.count)))
                }
            } else if key.hasPrefix(redirectUIDKeyPrefix) {
                if let uid = value as? String, !uid.isEmpty {
                    result.insert(String(key.dropFirst(redirectUIDKeyPrefix.count)))
                }
            }
        }

        cachedPinnedBundleIdentifiers = result
        return result
    }
}
