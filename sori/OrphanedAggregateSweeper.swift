import AudioToolbox

/// Startup-only cleanup for aggregate devices leaked by a previous, crashed
/// launch of Sori. Every `ProcessAudioTapEngine`-created aggregate is named
/// `Sori-Tap-<uuid>` and unregistered from `SoriOwnedAggregateDevices` on
/// clean teardown (`stop()`/`deinit`) - but a crash skips that teardown
/// entirely, leaving the device behind in coreaudiod's registry with no
/// process left alive to ever destroy it. Confirmed live: Sori has crashed
/// in the field, and those orphans accumulate across launches - the likely
/// source of `kAudioHardwareIllegalOperationError` ('nope') conflicts that
/// `ProcessAudioTapEngine.createAggregateDevice`'s own retry can't resolve,
/// since that retry only tears down THIS instance's own prior aggregate, not
/// a different, already-dead process's.
enum OrphanedAggregateSweeper {
    private static let namePrefix = "Sori-Tap-"

    /// Destroys every currently-enumerable aggregate device named
    /// `Sori-Tap-<something>` that isn't tracked in
    /// `SoriOwnedAggregateDevices` - i.e. not something this process itself
    /// created (impossible at the point this must run anyway - see below),
    /// so only something orphaned by an earlier process. Returns the number
    /// of devices destroyed, so the caller can log it - if this is ever
    /// nonzero during normal use (not a deliberate test), that's a signal
    /// Sori is still crashing somewhere.
    ///
    /// Must run once, at launch, on the main thread, before any
    /// `ProcessAudioTapEngine` starts - there's no live tap to race with an
    /// in-flight `AudioHardwareDestroyAggregateDevice` call that way, and
    /// nothing this process has created yet could be mistaken for an orphan.
    /// Two safety checks before ever destroying anything, neither sufficient
    /// alone: the `Sori-Tap-` name prefix, AND `isAggregateDevice`
    /// (transport type) - a user's own real device that merely happens to
    /// share the name prefix is never touched.
    @discardableResult
    static func sweepAtLaunch() -> Int {
        guard let deviceIDs = try? AudioObjectID.readDeviceList() else {
            SoriDebugLog.log("OrphanedAggregateSweeper: failed to read device list, skipping sweep")
            return 0
        }

        var sweptCount = 0
        for deviceID in deviceIDs {
            guard let name = try? deviceID.readString(kAudioObjectPropertyName),
                  name.hasPrefix(namePrefix) else { continue }
            guard deviceID.isAggregateDevice else {
                SoriDebugLog.log("OrphanedAggregateSweeper: #\(deviceID) name=\(name) matches name prefix but is NOT an aggregate device - not touching it")
                continue
            }

            // This runs before this process has created anything, so in
            // practice every match here is an orphan by construction - this
            // check is defense-in-depth, not the primary guard, in case
            // that invariant ever stops holding (e.g. this function gets
            // called from somewhere else later).
            if let uid = try? deviceID.readDeviceUID(), SoriOwnedAggregateDevices.shared.contains(uid) {
                continue
            }

            let destroyErr = AudioHardwareDestroyAggregateDevice(deviceID)
            if destroyErr == noErr {
                sweptCount += 1
                SoriDebugLog.log("OrphanedAggregateSweeper: destroyed orphaned aggregate #\(deviceID) name=\(name)")
            } else {
                SoriDebugLog.log("OrphanedAggregateSweeper: failed to destroy #\(deviceID) name=\(name) -> \(destroyErr)")
            }
        }

        SoriDebugLog.log("OrphanedAggregateSweeper: swept \(sweptCount) orphaned aggregate(s) at launch")
        return sweptCount
    }
}
