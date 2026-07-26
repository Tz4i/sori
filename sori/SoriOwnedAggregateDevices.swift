import Foundation

/// Tracks the device UID of every private aggregate `ProcessAudioTapEngine`
/// currently has open, across every engine instance and whichever thread
/// creates/destroys them.
///
/// Exists because of a confirmed-live surprise: a private aggregate device
/// (`kAudioAggregateDeviceIsPrivateKey = true`) is invisible to *other*
/// processes enumerating `kAudioHardwarePropertyDevices`, but IS visible to
/// its own creating process's enumeration of that same property. Verifying
/// "is my private aggregate hidden" from a separate throwaway process (as
/// was done once here) gives a falsely reassuring answer - the real
/// question is only meaningful asked from inside the owning process.
/// Without this filter, `AvailableAudioDevices` would see its own
/// freshly-created (and randomly-UUID-named) aggregate as a "new device"
/// every single time any tap anywhere in the app rebuilds, which is exactly
/// what caused a self-sustaining rebuild loop (device list "changes" ->
/// every redirect target re-resolves -> rebuild -> new aggregate UUID ->
/// device list "changes" again, forever).
final class SoriOwnedAggregateDevices: @unchecked Sendable {
    static let shared = SoriOwnedAggregateDevices()

    private let lock = NSLock()
    private var uids: Set<String> = []

    private init() {}

    func register(_ uid: String) {
        lock.lock()
        uids.insert(uid)
        lock.unlock()
    }

    func unregister(_ uid: String) {
        lock.lock()
        uids.remove(uid)
        lock.unlock()
    }

    func contains(_ uid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uids.contains(uid)
    }
}
