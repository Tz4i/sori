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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        do {
            let processObjectIDs = try AudioObjectID.readProcessObjectList()

            // Authority on "is this actually a running application" (as
            // opposed to a launchd background daemon that just happens to be
            // packaged as an .app bundle, e.g. a HAL plug-in's helper agent
            // living at ".../Some.driver/Contents/Resources/Some Agent.app").
            // Such a daemon's own executable path climbs to a real .app
            // bundle too, but it was never actually launched as an
            // application, so it won't show up here - unlike a genuine
            // multi-process app (Discord, Chrome), which will, via its main
            // process's own entry.
            let runningApps = NSWorkspace.shared.runningApplications
            let runningApplicationBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))
            let runningAppsByPID = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) })
            let runningAppsByName = Dictionary(
                runningApps.compactMap { app in app.localizedName.map { ($0, app) } },
                uniquingKeysWith: { first, _ in first }
            )

            var pidsByGroupKey: [String: Set<pid_t>] = [:]
            var infoByGroupKey: [String: (name: String, icon: NSImage?)] = [:]

            for objectID in processObjectIDs {
                guard let pid = try? objectID.readProcessPID(), pid > 0, pid != ownPID else { continue }
                guard objectID.readProcessIsRunningOutput() else { continue }

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
                } else if let directApp, let owner = Self.resolveWebKitHelperOwner(named: directApp.localizedName, runningAppsByName: runningAppsByName) {
                    candidateURL = owner.bundleURL
                } else if let owningApp = Self.resolveOwningApp(forPID: pid, runningAppsByPID: runningAppsByPID) {
                    candidateURL = owningApp.bundleURL
                } else {
                    candidateURL = Self.executableURL(for: pid)
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
                      runningApplicationBundleIDs.contains(groupKey) else { continue }

                pidsByGroupKey[groupKey, default: []].insert(pid)

                if infoByGroupKey[groupKey] == nil {
                    let name = topLevelBundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? topLevelBundle.infoDictionary?["CFBundleName"] as? String
                        ?? FileManager.default.displayName(atPath: topLevelURL.path)
                    let icon = NSWorkspace.shared.icon(forFile: topLevelURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    infoByGroupKey[groupKey] = (name, icon)
                }
            }

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

                if let runningApp = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
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

            entries = updatedEntries

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

        volumeControllers = updated
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
