import AudioToolbox
import Observation
import OSLog

/// Live, app-lifetime-shared list of every output- and input-capable Core
/// Audio device, used by both the per-app "Redirect Audio To" menu and the
/// System section's Output/Input device pickers. A single instance is
/// constructed once in `SoriApp` and handed to everything that needs it, so
/// there's one shared view of "what devices exist right now" rather than
/// each consumer polling independently.
///
/// Listens for `kAudioHardwarePropertyDevices` changes (device connect/
/// disconnect) rather than polling, so hot-plug is reflected immediately -
/// this is what lets a redirected app's tap notice its target device
/// disappeared and fall back (see `AppVolumeController.effectiveRedirectDeviceID`).
@MainActor
@Observable
final class AvailableAudioDevices {
    struct Device: Identifiable, Equatable, Hashable {
        var id: String { uid }
        let uid: String
        let objectID: AudioObjectID
        let name: String
    }

    private let logger = Logger(subsystem: "com.sebastianzapata.sori", category: "AvailableAudioDevices")

    private(set) var outputDevices: [Device] = []
    private(set) var inputDevices: [Device] = []

    @ObservationIgnored nonisolated(unsafe) private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        registerListener()
    }

    deinit {
        guard let listenerBlock else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(.systemObject, &address, .main, listenerBlock)
    }

    func outputDeviceID(forUID uid: String) -> AudioObjectID? {
        outputDevices.first(where: { $0.uid == uid })?.objectID
    }

    func inputDeviceID(forUID uid: String) -> AudioObjectID? {
        inputDevices.first(where: { $0.uid == uid })?.objectID
    }

    private func registerListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            SoriDebugLog.log("AvailableAudioDevices: kAudioHardwarePropertyDevices listener FIRED")
            Task { @MainActor in self?.refresh() }
        }
        listenerBlock = block

        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectAddPropertyListenerBlock(.systemObject, &address, .main, block)
        if err != noErr {
            logger.warning("Failed to register device-list listener: \(err, privacy: .public)")
        }
    }

    private func refresh() {
        guard let ids = try? AudioObjectID.readDeviceList() else {
            logger.error("Failed to read device list")
            return
        }

        var newOutputs: [Device] = []
        var newInputs: [Device] = []

        for id in ids {
            guard let uid = try? id.readDeviceUID(), !uid.isEmpty else { continue }
            // A private aggregate is invisible to OTHER processes enumerating
            // this same property, but IS visible to its own creating process
            // - i.e. us. Without this filter, every one of Sori's own
            // freshly-UUID-named per-tap aggregates would show up here as a
            // "new device," which is exactly what caused a self-sustaining
            // rebuild loop (see CLAUDE.md). `SoriOwnedAggregateDevices` is
            // the source of truth for "did Sori itself create this."
            guard !SoriOwnedAggregateDevices.shared.contains(uid) else { continue }
            let name = (try? id.readString(kAudioObjectPropertyName)) ?? uid
            let device = Device(uid: uid, objectID: id, name: name)

            if id.streamCount(scope: kAudioDevicePropertyScopeOutput) > 0 {
                newOutputs.append(device)
            }
            if id.streamCount(scope: kAudioDevicePropertyScopeInput) > 0 {
                newInputs.append(device)
            }
        }

        newOutputs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        newInputs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if SoriDebugLog.isEnabled {
            let oldOutputUIDs = Set(outputDevices.map(\.uid))
            let newOutputUIDs = Set(newOutputs.map(\.uid))
            let oldInputUIDs = Set(inputDevices.map(\.uid))
            let newInputUIDs = Set(newInputs.map(\.uid))
            SoriDebugLog.log("AvailableAudioDevices.refresh(): outputs=\(newOutputs.map { "\($0.name)[\($0.objectID)]" }) contentChanged=\(oldOutputUIDs != newOutputUIDs || oldInputUIDs != newInputUIDs)")
        }

        outputDevices = newOutputs
        inputDevices = newInputs
    }
}
