import AppKit
import AudioToolbox
import Darwin
import Observation
import OSLog
import UniformTypeIdentifiers

/// One row in the menu: a single app, collapsing every PID that belongs to it
/// (e.g. Chrome's or Discord's many helper processes) into one entry.
/// `pids` are the actual tap targets for later steps; `bundleIdentifier` is
/// the stable identity the UI and any per-app settings key off of.
struct AudioAppEntry: Identifiable, Equatable {
    var bundleIdentifier: String
    var displayName: String
    var icon: NSImage?
    var pids: Set<pid_t>
    /// True while this app is actually producing audio right now. False
    /// means it's silent but "pinned" in the list (seen playing at least
    /// once this session, or has a remembered non-default gain/mute setting)
    /// - the row stays put so its setting is visible and stays adjustable,
    /// but nothing is being tapped (see `AppVolumeController` - no active
    /// pids means no tap).
    var isActive: Bool

    var id: String { bundleIdentifier }

    static func == (lhs: AudioAppEntry, rhs: AudioAppEntry) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
        lhs.displayName == rhs.displayName &&
        lhs.pids == rhs.pids &&
        lhs.isActive == rhs.isActive
    }
}

/// Polls Core Audio's process object list for apps currently producing audio
/// and groups their PIDs by their *owning* app. Self-starting: begins polling
/// as soon as it's created and keeps `entries` live for as long as this
/// instance exists, so a SwiftUI view reading `entries` stays current without
/// needing to reopen the menu.
@MainActor
@Observable
final class AudioProcessMonitor {
    private let logger = Logger(subsystem: "com.sebastianzapata.sori", category: "AudioProcessMonitor")

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private let availableDevices: AvailableAudioDevices

    private(set) var entries: [AudioAppEntry] = []
    /// Per-app volume state, keyed by the same top-level bundle identifier
    /// used for `AudioAppEntry.id` - only exists for apps currently in
    /// `entries` (see `everActiveBundleIdentifiers` for why an app stays in
    /// `entries`, and so keeps a controller, well after it goes quiet). Gain
    /// settings persist in UserDefaults (see `AppVolumeController`), not
    /// here; a fresh controller reloads them from there.
    private(set) var volumeControllers: [String: AppVolumeController] = [:]

    // deinit on a @MainActor class runs nonisolated by default, so this can't
    // be a normal actor-isolated stored property if we want to invalidate it
    // there; it's only ever touched from `init`/`refresh`/`deinit`, all on
    // the main thread in practice. @ObservationIgnored since @Observable's
    // macro-generated tracking storage is incompatible with `nonisolated`.
    @ObservationIgnored
    nonisolated(unsafe) private var timer: Timer?
    // Only the bundleID -> pids shape, so refreshed icon/name instances
    // don't cause us to log on every single poll when nothing actually changed.
    private var lastLoggedSignature: [String: Set<pid_t>] = [:]

    /// Every bundle ID seen actively producing audio at least once this
    /// session - once an app has played, it stays in the list (dimmed) when
    /// silent, regardless of whether its gain was ever touched. Session-only
    /// (not persisted): a fresh launch of Sori starts this empty again, same
    /// as a fresh volume mixer would. This is separate from
    /// `AppVolumeController`'s persisted gain, which is what actually needs
    /// to survive relaunches.
    private var everActiveBundleIdentifiers: Set<String> = []

    /// pid -> resolved owning app's top-level bundle URL and bundle
    /// identifier ("group key"). A given pid's owning app can't change over
    /// its lifetime, so once the 4-layer resolution chain below (direct
    /// NSRunningApplication -> WebKit name-suffix match -> parent-chain walk
    /// -> proc_pidpath + bundle climb) has answered for a pid once, later
    /// polls (every 250ms) can skip straight to the cached answer instead of
    /// re-running that whole chain for every live pid on every single tick.
    /// Evicted for any pid no longer present in the process object list at
    /// all (see the `livePIDs` cleanup at the end of `refresh()`) - a pid
    /// that's merely gone quiet (`isRunningOutput == false`) but still
    /// exists keeps its cache entry, since it's cheap to keep and correct to
    /// reuse the next time it resumes.
    private var groupKeyCache: [pid_t: (groupKey: String, topLevelBundleURL: URL)] = [:]

    /// pids that resolution has determined AREN'T a genuine, currently-running
    /// top-level app (a background daemon, an already-exited process caught
    /// mid-transition, ...) - negative-cache counterpart to `groupKeyCache`,
    /// so a pid that will never resolve (e.g. a daemon that keeps producing
    /// audio every tick) doesn't retry the resolution chain - or worse,
    /// trigger the one-fallback-rebuild-per-tick path below - on every single
    /// poll for as long as it keeps running. Evicted the same way as
    /// `groupKeyCache`.
    private var unresolvablePIDs: Set<pid_t> = []

    /// pid -> app lookups, rebuilt from `NSWorkspace.shared.runningApplications`
    /// only when `runningAppsCacheDirty` - NOT on every 250ms poll tick.
    /// Profiled live: re-snapshotting `runningApplications` and rebuilding
    /// both dictionaries from scratch every tick was ~16-24ms of a ~31-39ms
    /// tick, by far the dominant per-tick cost (the whole rest of `refresh()`
    /// combined was under 3ms). `didLaunchApplicationNotification`/
    /// `didTerminateApplicationNotification` are the only two notifications
    /// that can actually change the pid -> owning-app mapping this cache
    /// exists to serve - hide/unhide, activate/deactivate, etc. don't affect
    /// it and aren't observed.
    private var cachedRunningApps: [NSRunningApplication] = []
    private var cachedRunningApplicationBundleIDs: Set<String> = []
    private var cachedRunningAppsByPID: [pid_t: NSRunningApplication] = [:]
    private var cachedRunningAppsByName: [String: NSRunningApplication] = [:]
    /// Starts `true` so the very first `refresh()` call (from `init`) builds
    /// the cache instead of running against empty dictionaries. Set `true`
    /// again by the launch/terminate notification handlers; consumed (rebuilt
    /// + reset to `false`) lazily at the top of the next `refresh()` tick -
    /// never rebuilt synchronously inside the notification handler itself, so
    /// a burst of several launches/terminations between two polls still costs
    /// exactly one rebuild, not one per notification.
    private var runningAppsCacheDirty = true

    @ObservationIgnored
    nonisolated(unsafe) private var launchObserver: NSObjectProtocol?
    @ObservationIgnored
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored
    nonisolated(unsafe) private var defaultSystemOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Snapshot of output device UIDs as of the last poll - compared each
    /// cycle to detect hot-plug so every controller with a redirect
    /// preference gets a chance to re-resolve it (see
    /// `AppVolumeController.refreshTapForRedirectChange`).
    /// `AvailableAudioDevices` itself reacts to hot-plug immediately via a
    /// property listener; this just piggybacks on the existing 1s
    /// reconciliation poll to propagate that to every controller, rather
    /// than wiring a second push/callback path.
    private var lastKnownOutputDeviceUIDs: Set<String> = []

    // 1.0s -> 0.25s: at 1s, a redirected/gain-adjusted app's audio could play
    // unmanaged on the system default for up to a second after the user hit
    // play, before this monitor even noticed the new pid and engaged the
    // tap - confirmed live. 250ms shrinks that window; see CLAUDE.md for the
    // measured CPU cost and for why event-driven detection (tried as the
    // "real" fix for this) did or didn't replace polling here.
    init(availableDevices: AvailableAudioDevices, pollInterval: TimeInterval = 0.25) {
        self.availableDevices = availableDevices

        // Only these two notifications can change the pid -> owning-app
        // mapping `cachedRunningApps...` exists to serve - mark the cache
        // dirty rather than rebuilding synchronously here, so a burst of
        // several launches/terminations between two polls still costs one
        // rebuild, consumed lazily at the top of the next `refresh()` tick.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        launchObserver = workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runningAppsCacheDirty = true }
        }
        terminateObserver = workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runningAppsCacheDirty = true }
        }

        registerDefaultSystemOutputDeviceListener()

        refresh()
        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        // `Timer.scheduledTimer` alone only fires in the `.default` run loop
        // mode, which `NSEventTrackingRunLoopMode` preempts while any NSMenu
        // (a redirect picker, the gear menu, ...) is open and tracking mouse
        // events - confirmed live: the app list froze for as long as a menu
        // stayed open. Adding to `.common` keeps it firing through that too.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    deinit {
        timer?.invalidate()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let launchObserver { workspaceCenter.removeObserver(launchObserver) }
        if let terminateObserver { workspaceCenter.removeObserver(terminateObserver) }
        if let defaultSystemOutputDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(.systemObject, &address, .main, defaultSystemOutputDeviceListenerBlock)
        }
    }

    /// Trap #17: `kAudioHardwarePropertyDefaultSystemOutputDevice`, NOT
    /// `kAudioHardwarePropertyDefaultOutputDevice` (the one
    /// `SystemDeviceVolumeController` watches for the System section's
    /// OUTPUT row - a genuinely different device on machines where "play
    /// sound effects/tapped audio through" differs from the main output).
    /// `ProcessAudioTapEngine.createAggregateDevice` has always targeted the
    /// *system* output device for every per-app tap's aggregate when there's
    /// no explicit redirect (pre-existing behavior, trap #17) - this must
    /// watch the same selector or it'll react to the wrong device changing
    /// and either miss real changes or fire spuriously.
    private func registerDefaultSystemOutputDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            SoriDebugLog.log("AudioProcessMonitor: kAudioHardwarePropertyDefaultSystemOutputDevice listener FIRED")
            Task { @MainActor in self?.handleDefaultSystemOutputDeviceChanged() }
        }
        defaultSystemOutputDeviceListenerBlock = block

        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectAddPropertyListenerBlock(.systemObject, &address, .main, block)
        if err != noErr {
            logger.warning("Failed to register default system output device listener: \(err, privacy: .public)")
        }
    }

    /// The system default OUTPUT device itself changed (user picked a new
    /// one in System Settings, an AirPods case closed and macOS auto-fell-
    /// back, ...) - tell every controller so each can decide for itself
    /// whether it's affected. Each call is a no-op unless that specific
    /// controller has BOTH no explicit redirect AND a currently-live tap -
    /// see `AppVolumeController.refreshTapForSystemDefaultOutputChange`.
    /// This is a distinct trigger from `refreshTapForRedirectChange` (fired
    /// by `AvailableAudioDevices`' device-LIST changing, i.e. hot-plug) -
    /// the two are mutually exclusive by construction (one only ever acts on
    /// redirected apps, the other only ever acts on non-redirected apps), so
    /// a single real-world event that happens to trigger both (e.g.
    /// unplugging the device that was both someone's redirect target AND
    /// the system default) can't double-rebuild the same controller from
    /// both paths.
    private func handleDefaultSystemOutputDeviceChanged() {
        SoriDebugLog.log("AudioProcessMonitor: default system output device changed - notifying \(volumeControllers.count) controller(s)")
        for controller in volumeControllers.values {
            controller.refreshTapForSystemDefaultOutputChange()
        }
    }

    private func refresh() {
        do {
            let processObjectIDs = try AudioObjectID.readProcessObjectList()

            // Consumes `runningAppsCacheDirty` if the launch/terminate
            // observers set it since the last tick - a no-op the other
            // ~99% of ticks where nothing launched or quit.
            rebuildRunningAppsCacheIfNeeded()

            var pidsByGroupKey: [String: Set<pid_t>] = [:]
            var infoByGroupKey: [String: (name: String, icon: NSImage?)] = [:]
            var livePIDs: Set<pid_t> = []
            // At most one extra forced re-snapshot per tick, regardless of
            // how many pids fail resolution against the current cache - see
            // the fallback branch below.
            var didFallbackRefreshThisTick = false

            for objectID in processObjectIDs {
                guard let pid = try? objectID.readProcessPID(), pid > 0, pid != ownPID else { continue }
                livePIDs.insert(pid)
                guard objectID.readProcessIsRunningOutput() else { continue }

                // A pid's owning app can't change over its lifetime, so once
                // resolved, later polls (every 250ms) skip straight to the
                // cached answer instead of re-running the whole
                // NSRunningApplication/WebKit-suffix/parent-chain/bundle-climb
                // resolution chain below for every live pid on every tick.
                let groupKey: String
                let topLevelURL: URL

                if let cached = groupKeyCache[pid] {
                    groupKey = cached.groupKey
                    topLevelURL = cached.topLevelBundleURL
                } else if unresolvablePIDs.contains(pid) {
                    continue
                } else {
                    var resolved = Self.resolveGroupKey(
                        forPID: pid,
                        ownBundleIdentifier: ownBundleIdentifier,
                        runningApplicationBundleIDs: cachedRunningApplicationBundleIDs,
                        runningAppsByPID: cachedRunningAppsByPID,
                        runningAppsByName: cachedRunningAppsByName
                    )

                    if resolved == nil, !didFallbackRefreshThisTick {
                        // Could genuinely be unresolvable, OR a brand-new
                        // app whose NSWorkspace entry hasn't reached our
                        // cache yet - a race between this poll tick and the
                        // didLaunchApplicationNotification that would
                        // otherwise have marked the cache dirty. Force one
                        // fresh snapshot and retry before giving up on it.
                        didFallbackRefreshThisTick = true
                        rebuildRunningAppsCache()
                        resolved = Self.resolveGroupKey(
                            forPID: pid,
                            ownBundleIdentifier: ownBundleIdentifier,
                            runningApplicationBundleIDs: cachedRunningApplicationBundleIDs,
                            runningAppsByPID: cachedRunningAppsByPID,
                            runningAppsByName: cachedRunningAppsByName
                        )
                    }

                    guard let resolved else {
                        unresolvablePIDs.insert(pid)
                        continue
                    }
                    groupKey = resolved.groupKey
                    topLevelURL = resolved.topLevelBundleURL
                    groupKeyCache[pid] = resolved
                }

                pidsByGroupKey[groupKey, default: []].insert(pid)

                if infoByGroupKey[groupKey] == nil, let topLevelBundle = Bundle(url: topLevelURL) {
                    let name = topLevelBundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? topLevelBundle.infoDictionary?["CFBundleName"] as? String
                        ?? FileManager.default.displayName(atPath: topLevelURL.path)
                    let icon = NSWorkspace.shared.icon(forFile: topLevelURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    infoByGroupKey[groupKey] = (name, icon)
                }
            }

            // Evict any pid that's gone entirely (process exited) - a pid
            // that's merely stopped producing output right now but still
            // exists keeps its cache entry.
            groupKeyCache = groupKeyCache.filter { livePIDs.contains($0.key) }
            unresolvablePIDs = unresolvablePIDs.intersection(livePIDs)

            // An app stays "pinned" in the list (dimmed, empty pid set - no
            // tap held open) for the rest of this session once EITHER it's
            // been seen playing at all, OR the user has touched its
            // slider/mute at all - permanently, not on a timer (a
            // time-limited grace period here was tried and confirmed live to
            // cause a row to vanish a few seconds after being set to exactly
            // 100%, since that's often the last interaction before the
            // window quietly expired). Apps never seen active AND never
            // touched still only appear while actually producing audio, so
            // the list doesn't flood with everything ever opened.
            everActiveBundleIdentifiers.formUnion(pidsByGroupKey.keys)
            for (bundleID, controller) in volumeControllers where controller.hasBeenInteractedWith {
                everActiveBundleIdentifiers.insert(bundleID)
            }

            var pinnedBundleIdentifiers = everActiveBundleIdentifiers
            pinnedBundleIdentifiers.formUnion(AppVolumeController.pinnedBundleIdentifiers())

            if ProcessInfo.processInfo.environment["SORI_DEBUG_PROCESS_MONITOR"] == "1" {
                let interacted = volumeControllers.filter { $0.value.hasBeenInteractedWith }.keys.sorted()
                FileHandle.standardError.write("SORI_PM_PIN: everActive=\(everActiveBundleIdentifiers.sorted()) interacted=\(interacted) pinned=\(pinnedBundleIdentifiers.sorted()) currentlyLive=\(pidsByGroupKey.keys.sorted())\n".data(using: .utf8)!)
            }

            for bundleID in pinnedBundleIdentifiers {
                guard bundleID != ownBundleIdentifier, pidsByGroupKey[bundleID] == nil else { continue }

                if let runningApp = cachedRunningApps.first(where: { $0.bundleIdentifier == bundleID }) {
                    pidsByGroupKey[bundleID] = []
                    infoByGroupKey[bundleID] = (runningApp.localizedName ?? bundleID, runningApp.icon)
                } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    pidsByGroupKey[bundleID] = []
                    let bundle = Bundle(url: appURL)
                    let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? bundle?.infoDictionary?["CFBundleName"] as? String
                        ?? FileManager.default.displayName(atPath: appURL.path)
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    infoByGroupKey[bundleID] = (name, icon)
                }
                // Else: not running and not installed/discoverable anymore -
                // nothing to show a name/icon for, so leave it out. Its
                // persisted setting is untouched in case the same bundle ID
                // shows up again later.
            }

            let updatedEntries = pidsByGroupKey.compactMap { groupKey, pids -> AudioAppEntry? in
                guard let info = infoByGroupKey[groupKey] else { return nil }
                return AudioAppEntry(
                    bundleIdentifier: groupKey,
                    displayName: info.name,
                    icon: info.icon,
                    pids: pids,
                    isActive: !pids.isEmpty
                )
            }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

            // Guarded on inequality (AudioAppEntry has a hand-written `==`):
            // @Observable notifies every reader of `entries` on assignment
            // regardless of whether the new array is actually different, and
            // most poll ticks (4x/sec) resolve to exactly the same state -
            // an unconditional assignment here woke SwiftUI every tick for
            // nothing.
            if updatedEntries != entries {
                entries = updatedEntries
            }

            let currentOutputDeviceUIDs = Set(availableDevices.outputDevices.map(\.uid))
            let deviceListChanged = currentOutputDeviceUIDs != lastKnownOutputDeviceUIDs
            if deviceListChanged {
                SoriDebugLog.log("AudioProcessMonitor: output device UID set changed \(lastKnownOutputDeviceUIDs) -> \(currentOutputDeviceUIDs); propagating refreshTapForRedirectChange to all controllers")
            }
            lastKnownOutputDeviceUIDs = currentOutputDeviceUIDs

            updateVolumeControllers(with: pidsByGroupKey, redirectTargetsMayHaveChanged: deviceListChanged)

            if pidsByGroupKey != lastLoggedSignature {
                lastLoggedSignature = pidsByGroupKey
                logGroups(updatedEntries)
                if ProcessInfo.processInfo.environment["SORI_DEBUG_PROCESS_MONITOR"] == "1" {
                    dumpGroupsToStderr(updatedEntries)
                }
            }
        } catch {
            logger.error("Failed to read process object list: \(error, privacy: .public)")
        }
    }

    /// Rebuilds `cachedRunningApps...` only if `runningAppsCacheDirty` -
    /// called at the top of every `refresh()` tick, but a no-op the
    /// overwhelming majority of ticks (nothing launched or quit since the
    /// last one).
    private func rebuildRunningAppsCacheIfNeeded() {
        guard runningAppsCacheDirty else { return }
        rebuildRunningAppsCache()
    }

    /// Unconditional rebuild - called by `rebuildRunningAppsCacheIfNeeded()`
    /// when dirty, and directly (bypassing the dirty check) by `refresh()`'s
    /// per-pid loop as a last-resort fallback when a pid fails to resolve
    /// against the current cache, in case that's a genuinely fresh app launch
    /// racing this poll tick rather than a truly unresolvable process.
    private func rebuildRunningAppsCache() {
        // Authority on "is this actually a running application" (as opposed
        // to a launchd background daemon that just happens to be packaged as
        // an .app bundle, e.g. a HAL plug-in's helper agent living at
        // ".../Some.driver/Contents/Resources/Some Agent.app"). Such a
        // daemon's own executable path climbs to a real .app bundle too, but
        // it was never actually launched as an application, so it won't show
        // up here - unlike a genuine multi-process app (Discord, Chrome),
        // which will, via its main process's own entry.
        let apps = NSWorkspace.shared.runningApplications
        cachedRunningApps = apps
        cachedRunningApplicationBundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        // NSRunningApplication.processIdentifier returns -1 (or, in principle,
        // could otherwise collide) for an app that's transitioning in/out of
        // existence - not a valid audio process, and not a safe dictionary
        // key. Confirmed live as the cause of a real crash: two apps in that
        // transient state during the same poll produced two `-1` entries,
        // and `Dictionary(uniqueKeysWithValues:)` fatal-traps on a duplicate
        // key. Filter those out first, then use `uniquingKeysWith:` (same
        // pattern as the name dictionary below) as defense-in-depth so even
        // a genuine collision degrades to "first one wins" instead of
        // crashing.
        cachedRunningAppsByPID = Dictionary(
            apps.compactMap { app in app.processIdentifier > 0 ? (app.processIdentifier, app) : nil },
            uniquingKeysWith: { first, _ in first }
        )
        cachedRunningAppsByName = Dictionary(
            apps.compactMap { app in app.localizedName.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        runningAppsCacheDirty = false
    }

    /// Keeps `volumeControllers` in sync with the current set of
    /// audio-producing apps: creates a controller for a newly-seen app
    /// (reloading any persisted gain for it), feeds every controller its
    /// current PID set (so an active tap gets rebuilt if e.g. a new Chrome
    /// tab starts playing), and tears down + drops controllers for apps that
    /// stopped producing audio.
    private func updateVolumeControllers(with pidsByGroupKey: [String: Set<pid_t>], redirectTargetsMayHaveChanged: Bool) {
        var updated: [String: AppVolumeController] = [:]

        for (groupKey, pids) in pidsByGroupKey {
            let controller = volumeControllers[groupKey] ?? AppVolumeController(bundleIdentifier: groupKey, availableDevices: availableDevices)
            controller.updatePIDs(pids)
            if redirectTargetsMayHaveChanged {
                controller.refreshTapForRedirectChange()
            }
            updated[groupKey] = controller
        }

        for (groupKey, controller) in volumeControllers where updated[groupKey] == nil {
            controller.updatePIDs([])
        }

        // Same reasoning as the `entries` guard above: `updated` is a fresh
        // dictionary built every tick even when nothing changed, since
        // `AppVolumeController` is a class - compare by key set + identity of
        // the controller stored at each key (not `==`, which the class
        // doesn't conform to) rather than assigning unconditionally.
        let controllersChanged = updated.count != volumeControllers.count
            || updated.contains { key, controller in volumeControllers[key] !== controller }
        if controllersChanged {
            volumeControllers = updated
        }
    }

    private func logGroups(_ entries: [AudioAppEntry]) {
        guard !entries.isEmpty else {
            logger.notice("Audio-producing apps: none")
            return
        }

        for entry in entries {
            let pidList = entry.pids.sorted().map(String.init).joined(separator: ", ")
            logger.notice("\(entry.bundleIdentifier, privacy: .public) -> [\(pidList, privacy: .public)]  (\(entry.displayName, privacy: .public), \(entry.pids.count, privacy: .public) pid(s))")
        }
    }

    /// Mirrors `logGroups` to stderr, for verification without depending on
    /// unified-log delivery timing.
    private func dumpGroupsToStderr(_ entries: [AudioAppEntry]) {
        if entries.isEmpty {
            FileHandle.standardError.write("SORI_PM_GROUPS: (none)\n".data(using: .utf8)!)
        }
        for entry in entries {
            let pidList = entry.pids.sorted().map(String.init).joined(separator: ", ")
            FileHandle.standardError.write("SORI_PM_GROUPS: \(entry.bundleIdentifier) -> [\(pidList)]  (\(entry.displayName), \(entry.pids.count) pid(s))\n".data(using: .utf8)!)
        }
    }

    /// The 4-layer pid -> owning-app resolution chain, factored out of
    /// `refresh()`'s loop so it can be skipped entirely on a `groupKeyCache`
    /// hit. Returns `nil` for a pid that doesn't resolve to a genuine,
    /// currently-running top-level app (see the inline case-by-case
    /// reasoning below - unchanged from the original inline version, just
    /// relocated).
    private static func resolveGroupKey(
        forPID pid: pid_t,
        ownBundleIdentifier: String?,
        runningApplicationBundleIDs: Set<String>,
        runningAppsByPID: [pid_t: NSRunningApplication],
        runningAppsByName: [String: NSRunningApplication]
    ) -> (groupKey: String, topLevelBundleURL: URL)? {
        let directApp = NSRunningApplication(processIdentifier: pid)

        // Three different ways a process's own NSRunningApplication
        // entry can be the wrong (or missing) thing to resolve from,
        // all confirmed live:
        //
        // 1. No entry at all - Chromium/Electron sandboxed *utility*
        //    helpers (e.g. Discord's actual audio-rendering helper,
        //    "Discord PTB Helper.app", spawned with --type=utility)
        //    are launched directly via posix_spawn and never register
        //    with LaunchServices. But they're still genuinely nested
        //    inside their app's bundle on disk, so climbing from the
        //    raw executable path (proc_pidpath) still finds it.
        //
        // 2. An entry exists, but its bundle is a truly SHARED,
        //    launchd-spawned system service - Safari/Modrinth/every
        //    other WebKit-embedding app's audio renders through
        //    "com.apple.WebKit.GPU" (or "...WebContent"), whose
        //    bundle lives under WebKit.framework itself, spawned
        //    on-demand by launchd (confirmed live: its parent pid is
        //    1, i.e. launchd - no process-tree link back to Safari at
        //    all, so climbing bundle paths OR walking the parent
        //    chain both dead-end here). The only signal that
        //    actually encodes which app owns this particular
        //    instance is the one macOS itself assigns it: its
        //    NSRunningApplication.localizedName is literally
        //    "<Owning App> Graphics and Media" (confirmed live:
        //    "Safari Graphics and Media"). Stripping that suffix and
        //    matching the remainder against a currently-running app's
        //    own name recovers the real owner - cross-checked against
        //    NSWorkspace.runningApplications so a coincidental/stale
        //    name can't mislabel it.
        //
        // 3. A rarer variant of (2) where the name-suffix match
        //    fails - fall back to walking the parent-process chain in
        //    case some other shared helper *is* parented directly to
        //    its requesting app (unlike WebKit.GPU).
        let isSharedSystemHelper = directApp?.bundleIdentifier?.hasPrefix("com.apple.WebKit.") == true

        let candidateURL: URL?
        if let directApp, !isSharedSystemHelper {
            candidateURL = directApp.bundleURL
        } else if let directApp, let owner = resolveWebKitHelperOwner(named: directApp.localizedName, runningAppsByName: runningAppsByName) {
            candidateURL = owner.bundleURL
        } else if let owningApp = resolveOwningApp(forPID: pid, runningAppsByPID: runningAppsByPID) {
            candidateURL = owningApp.bundleURL
        } else {
            candidateURL = executableURL(for: pid)
        }

        // Multi-process apps (Chrome, Discord, most Electron apps)
        // give their helper processes THEIR OWN, DIFFERENT bundle
        // identifiers (Discord's are "com.hnc.DiscordPTB",
        // "com.hnc.DiscordPTB.helper", "...helper.Renderer",
        // "...helper.Plugin" - four distinct strings, confirmed live).
        // Grouping by each process's own bundle id directly would
        // show four separate rows instead of one. Resolving each
        // process's bundle up to its enclosing top-level .app and
        // grouping by THAT bundle's identifier is what actually
        // collapses them - and also avoids the opposite mistake of
        // merging unrelated apps that happen to share a generic
        // system helper bundle id (e.g. every WebKit-embedding app
        // reports "com.apple.WebKit.GPU" for its GPU process).
        guard let topLevelURL = candidateURL?.topLevelAppBundleURL(),
              let topLevelBundle = Bundle(url: topLevelURL),
              let groupKey = topLevelBundle.bundleIdentifier,
              groupKey != ownBundleIdentifier,
              runningApplicationBundleIDs.contains(groupKey) else { return nil }

        return (groupKey, topLevelURL)
    }

    /// Known suffixes macOS appends to a WebKit XPC helper's own
    /// NSRunningApplication.localizedName to identify which app it's
    /// rendering for - e.g. "Safari Graphics and Media" for Safari's GPU
    /// process. Only "Graphics and Media" (the GPU process) has been
    /// confirmed live; the others are the documented equivalents for
    /// WebKit's other per-client XPC services and included defensively.
    private static let webKitHelperNameSuffixes = [
        " Graphics and Media",
        " Web Content",
        " Networking"
    ]

    private static func resolveWebKitHelperOwner(named name: String?, runningAppsByName: [String: NSRunningApplication]) -> NSRunningApplication? {
        guard let name else { return nil }
        for suffix in webKitHelperNameSuffixes where name.hasSuffix(suffix) {
            let ownerName = String(name.dropLast(suffix.count))
            if let owner = runningAppsByName[ownerName] {
                return owner
            }
        }
        return nil
    }

    private static func executableURL(for pid: pid_t) -> URL? {
        var buffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    /// Walks up the parent-process chain from `pid` looking for an ancestor
    /// whose pid IS a currently-running application (per
    /// `NSWorkspace.runningApplications`) - used to attribute a shared system
    /// XPC helper (WebKit's GPU/WebContent processes) back to whichever app
    /// actually spawned it, since there's no bundle-path relationship to
    /// climb for those. Bounded to a handful of hops so a broken/cyclic PPID
    /// chain can't spin forever.
    private static func resolveOwningApp(forPID pid: pid_t, runningAppsByPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        var currentPID = pid
        var hops = 0
        while hops < 8 {
            guard let parentPID = parentPID(of: currentPID), parentPID > 1, parentPID != currentPID else { return nil }
            if let app = runningAppsByPID[parentPID] { return app }
            currentPID = parentPID
            hops += 1
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }

        return info.kp_eproc.e_ppid
    }
}

private extension URL {
    var isAppBundle: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true
    }

    /// Climbs from this URL up to the filesystem root, returning the
    /// OUTERMOST ancestor directory that's an `.app` bundle (not just the
    /// nearest one) - so a helper nested several levels deep, e.g.
    /// ".../Discord PTB.app/Contents/Frameworks/Discord PTB Helper.app/...",
    /// resolves all the way back to "Discord PTB.app" rather than stopping
    /// at the first (innermost) `.app` it finds.
    func topLevelAppBundleURL() -> URL? {
        var current = self
        var result: URL? = current.isAppBundle ? current : nil

        while current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
            if current.isAppBundle { result = current }
        }

        return result
    }
}
