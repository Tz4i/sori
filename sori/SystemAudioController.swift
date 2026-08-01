import AudioToolbox
import Foundation
import Observation
import OSLog

/// Works out how to read/write `kAudioDevicePropertyVolumeScalar` on a device
/// that may only expose a true master (element 0) volume control, or only
/// per-channel controls (element 1, 2, ...) with no master at all - confirmed
/// live on this project's own dev hardware: neither the default output
/// device (AirPods, as main output) nor the default *system* output device
/// (a wired headset) expose a master element, only per-channel; a different
/// default input device (also AirPods) does expose a true master element.
/// Both shapes are common enough in the wild that every row needs the
/// fallback, not just an edge case.
struct HardwareVolumeAddressing {
    enum Mode: Equatable {
        case master
        case channels([AudioObjectPropertyElement])
        case unsupported
    }

    let mode: Mode
    /// False for a device that reports the property but doesn't allow
    /// writing it (e.g. some USB mics expose a read-only input level) - the
    /// caller should disable/grey its control rather than silently no-op on
    /// every drag.
    let isSettable: Bool

    static func resolve(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> HardwareVolumeAddressing {
        if deviceID.hasProperty(kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain) {
            let settable = deviceID.isPropertySettable(kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain)
            return HardwareVolumeAddressing(mode: .master, isSettable: settable)
        }

        // Probe a generous but bounded channel range rather than hardcoding
        // stereo - some devices may expose more.
        var channels: [AudioObjectPropertyElement] = []
        for element: AudioObjectPropertyElement in 1...8
        where deviceID.hasProperty(kAudioDevicePropertyVolumeScalar, scope: scope, element: element) {
            channels.append(element)
        }
        guard !channels.isEmpty else {
            return HardwareVolumeAddressing(mode: .unsupported, isSettable: false)
        }
        let settable = channels.allSatisfy { deviceID.isPropertySettable(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0) }
        return HardwareVolumeAddressing(mode: .channels(channels), isSettable: settable)
    }

    func read(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        switch mode {
        case .master:
            return try? deviceID.read(kAudioDevicePropertyVolumeScalar, scope: scope, defaultValue: Float32(0))
        case .channels(let channels):
            let values = channels.compactMap { try? deviceID.read(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0, defaultValue: Float32(0)) }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Float(values.count)
        case .unsupported:
            return nil
        }
    }

    func write(_ value: Float, deviceID: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard isSettable else { return }
        switch mode {
        case .master:
            deviceID.write(value, selector: kAudioDevicePropertyVolumeScalar, scope: scope)
        case .channels(let channels):
            for element in channels {
                deviceID.write(value, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            }
        case .unsupported:
            break
        }
    }

    /// Every element a property listener needs to watch to catch every way
    /// this device's volume can change underneath us (hardware media keys,
    /// System Settings, another app).
    var listenerElements: [AudioObjectPropertyElement] {
        switch mode {
        case .master: return [kAudioObjectPropertyElementMain]
        case .channels(let channels): return channels
        case .unsupported: return []
        }
    }
}

/// Live-syncing volume control for the system's default output or input
/// device (the "OUTPUT"/"INPUT" rows in the menu's System section) - distinct
/// from `AppVolumeController`, which controls one app's tap gain. There's no
/// Sori-side persistence for the volume level itself: the hardware property
/// is the persistent store, and this class is just a thin, always-live
/// reflection of it, so it re-reads and re-subscribes whenever the default
/// device changes out from under it (the user picks a new output in System
/// Settings, an AirPods case is closed, our own `selectDevice` call, etc).
///
/// Both rows are 0...1 - unlike per-app rows, there's no boost past unity
/// here. (A boost implementation - a second `.allExcluding` tap layered on
/// top of everything else hitting the output device - was built and
/// reasoned through in an earlier pass, but was removed again without ever
/// being confirmed working by ear; if this is revisited, note that a tap
/// re-rendering an app Sori is already individually tapping is attributed to
/// Sori's own PID at the HAL level, so `.allExcluding([ownProcessObjectID])`
/// would silently skip boosting anything already gain-adjusted or
/// redirected - a real gotcha for a future attempt.)
@MainActor
@Observable
final class SystemDeviceVolumeController {
    enum Kind: Equatable {
        case output
        case input

        var label: String {
            switch self {
            case .output: return "output"
            case .input: return "input"
            }
        }

        var defaultDeviceSelector: AudioObjectPropertySelector {
            switch self {
            case .output: return kAudioHardwarePropertyDefaultOutputDevice
            case .input: return kAudioHardwarePropertyDefaultInputDevice
            }
        }

        var scope: AudioObjectPropertyScope {
            switch self {
            case .output: return kAudioDevicePropertyScopeOutput
            case .input: return kAudioDevicePropertyScopeInput
            }
        }
    }

    let kind: Kind
    private let logger: Logger
    private let availableDevices: AvailableAudioDevices

    private(set) var sliderGain: Float = 0
    /// False when the current default device exposes no adjustable volume
    /// property at all (some USB mics report no settable gain) - the row
    /// should disable and grey its slider rather than silently no-op on
    /// every drag.
    private(set) var isSupported = false
    /// The current default device's UID, for driving the device picker's
    /// selection - `nil` if there's no default device at all.
    private(set) var currentDeviceUID: String?

    /// Devices this row's picker should offer - output devices for the
    /// OUTPUT row, input devices for the INPUT row.
    var deviceOptions: [AvailableAudioDevices.Device] {
        switch kind {
        case .output: return availableDevices.outputDevices
        case .input: return availableDevices.inputDevices
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var deviceID: AudioObjectID = .unknown
    @ObservationIgnored private var addressing = HardwareVolumeAddressing(mode: .unsupported, isSettable: false)
    @ObservationIgnored nonisolated(unsafe) private var registeredVolumeAddresses: [AudioObjectPropertyAddress] = []
    @ObservationIgnored nonisolated(unsafe) private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored nonisolated(unsafe) private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    init(kind: Kind, availableDevices: AvailableAudioDevices) {
        self.kind = kind
        self.availableDevices = availableDevices
        self.logger = Logger(subsystem: "com.sebastianzapata.sori", category: "SystemDeviceVolumeController.\(kind.label)")
        attachToCurrentDefaultDevice()
        registerDefaultDeviceListener()
    }

    deinit {
        if let volumeListenerBlock {
            for i in registeredVolumeAddresses.indices {
                AudioObjectRemovePropertyListenerBlock(deviceID, &registeredVolumeAddresses[i], .main, volumeListenerBlock)
            }
        }
        if let defaultDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(mSelector: kind.defaultDeviceSelector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(.systemObject, &address, .main, defaultDeviceListenerBlock)
        }
    }

    func setSlider(_ value: Float) {
        guard addressing.isSettable, deviceID.isValid else { return }
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - sliderGain) > 0.0001 else { return }
        sliderGain = clamped
        addressing.write(clamped, deviceID: deviceID, scope: kind.scope)
    }

    /// Changes the system-wide default output/input device -
    /// `kAudioHardwarePropertyDefaultOutputDevice`/`DefaultInputDevice` are
    /// themselves settable properties; writing one is the same effect as
    /// picking a new device in System Settings' Sound pane. This
    /// controller's own default-device-change listener picks up the
    /// resulting change and retargets everything (`attachToCurrentDefaultDevice`),
    /// same as if the OS or another app had changed it.
    func selectDevice(uid: String) {
        let resolvedID: AudioObjectID?
        switch kind {
        case .output: resolvedID = availableDevices.outputDeviceID(forUID: uid)
        case .input: resolvedID = availableDevices.inputDeviceID(forUID: uid)
        }
        guard let resolvedID, resolvedID.isValid else { return }
        let err = AudioObjectID.systemObject.write(resolvedID, selector: kind.defaultDeviceSelector)
        if err != noErr {
            logger.warning("Failed to set default \(self.kind.label, privacy: .public) device: \(err, privacy: .public)")
        }
    }

    // MARK: - Device targeting

    private func attachToCurrentDefaultDevice() {
        guard let newDeviceID = try? AudioObjectID.systemObject.read(kind.defaultDeviceSelector, defaultValue: AudioObjectID.unknown),
              newDeviceID.isValid else {
            deviceID = .unknown
            addressing = HardwareVolumeAddressing(mode: .unsupported, isSettable: false)
            isSupported = false
            currentDeviceUID = nil
            logger.warning("No default \(self.kind.label, privacy: .public) device available")
            return
        }

        deviceID = newDeviceID
        currentDeviceUID = try? newDeviceID.readDeviceUID()
        addressing = HardwareVolumeAddressing.resolve(deviceID: newDeviceID, scope: kind.scope)
        isSupported = addressing.mode != .unsupported

        if let value = addressing.read(deviceID: newDeviceID, scope: kind.scope) {
            sliderGain = value
        }

        if !isSupported {
            logger.notice("Default \(self.kind.label, privacy: .public) device #\(newDeviceID, privacy: .public) has no adjustable volume property")
        }

        registerVolumeListener()
    }

    /// The default device itself changed (user picked a new one, our own
    /// `selectDevice`, an AirPods case closed, ...).
    private func retargetToCurrentDefaultDevice() {
        unregisterVolumeListener()
        attachToCurrentDefaultDevice()
    }

    // MARK: - Listeners

    private func registerVolumeListener() {
        guard deviceID.isValid else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleHardwareVolumeChanged() }
        }
        volumeListenerBlock = block

        for element in addressing.listenerElements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kind.scope, mElement: element)
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                registeredVolumeAddresses.append(address)
            }
        }
    }

    private func unregisterVolumeListener() {
        guard let block = volumeListenerBlock, deviceID.isValid else {
            registeredVolumeAddresses = []
            volumeListenerBlock = nil
            return
        }
        for i in registeredVolumeAddresses.indices {
            AudioObjectRemovePropertyListenerBlock(deviceID, &registeredVolumeAddresses[i], .main, block)
        }
        registeredVolumeAddresses = []
        volumeListenerBlock = nil
    }

    private func registerDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.retargetToCurrentDefaultDevice() }
        }
        defaultDeviceListenerBlock = block

        var address = AudioObjectPropertyAddress(mSelector: kind.defaultDeviceSelector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectAddPropertyListenerBlock(.systemObject, &address, .main, block)
        if err != noErr {
            logger.warning("Failed to register default \(self.kind.label, privacy: .public) device listener: \(err, privacy: .public)")
        }
    }

    /// Fired by the hardware (media keys, System Settings, another app) -
    /// pulls the new value in and republishes it so this row stays in sync
    /// without the user having touched our own slider.
    private func handleHardwareVolumeChanged() {
        guard let hardwareValue = addressing.read(deviceID: deviceID, scope: kind.scope) else { return }
        guard abs(hardwareValue - sliderGain) > 0.001 else { return }
        sliderGain = hardwareValue
    }
}

/// Live-syncing control for macOS's alert/UI sound effects volume (System
/// Settings > Sound > Sound Effects > "Alert volume") - independent of the
/// main output volume.
///
/// Documented trap: this is NOT exposed anywhere in the Core Audio HAL
/// object property system, confirmed live by two separate checks: (1)
/// diffing a full dump of every `defaults` domain on the machine (`defaults
/// domains`, ~40 of them) before and after changing alert volume via
/// `osascript -e 'set volume alert volume N'` - zero domains changed, so
/// it isn't a CFPreferences-backed value like older macOS's documented
/// `com.apple.sound.beep.volume` key; and (2) reading
/// `kAudioDevicePropertyVolumeScalar` directly on
/// `kAudioHardwarePropertyDefaultSystemOutputDevice` (the actual device
/// alerts render through) and finding it holds a completely different,
/// independently-moving value from what `alert volume of (get volume
/// settings)` reports - so it isn't simply that device's own hardware
/// volume either. It's live, non-persisted, coreaudiod-internal state with
/// no discoverable `AudioObjectID` selector (grepped the CoreAudio,
/// AudioToolbox, and AudioHardwareService headers and exported symbols for
/// this SDK - nothing). The only stable, Apple-supported, working surface
/// for it is the Standard Additions "volume settings" / "set volume"
/// AppleScript command pair - the same thing System Settings' Sound pane and
/// `osascript` itself use - so that's what this drives, via `NSAppleScript`
/// executed in-process (confirmed live, round-trips correctly) rather than
/// shelling out to `osascript` per slider tick. There's no listener/
/// notification for it either, so external changes are caught by polling,
/// same cadence as `AudioProcessMonitor`.
@MainActor
@Observable
final class SystemAlertVolumeController {
    private let logger = Logger(subsystem: "com.sebastianzapata.sori", category: "SystemAlertVolumeController")

    private(set) var sliderGain: Float

    @ObservationIgnored nonisolated(unsafe) private var pollTimer: Timer?

    // Compiled once and reused: re-executing an already-compiled NSAppleScript
    // is cheap, but recompiling from source on every 1s poll tick isn't worth
    // paying for a script this small and constant.
    private static let getAlertVolumeScript = NSAppleScript(source: "alert volume of (get volume settings)")

    init(pollInterval: TimeInterval = 1.0) {
        self.sliderGain = Float(Self.readAlertVolumePercent() ?? 100) / 100.0
        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollForExternalChange() }
        }
        // Same NSEventTrackingRunLoopMode gotcha as AudioProcessMonitor's
        // poll timer - `.common` keeps this firing while a menu is open.
        RunLoop.main.add(newTimer, forMode: .common)
        pollTimer = newTimer
    }

    deinit {
        pollTimer?.invalidate()
    }

    func setSlider(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - sliderGain) > 0.0001 else { return }
        sliderGain = clamped
        Self.writeAlertVolumePercent(Int((clamped * 100).rounded()))
    }

    private func pollForExternalChange() {
        guard let percent = Self.readAlertVolumePercent() else { return }
        let value = Float(percent) / 100.0
        guard abs(value - sliderGain) > 0.001 else { return }
        sliderGain = value
    }

    private static func readAlertVolumePercent() -> Int? {
        guard let getAlertVolumeScript else { return nil }
        var error: NSDictionary?
        let result = getAlertVolumeScript.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return Int(result.int32Value)
    }

    private static func writeAlertVolumePercent(_ percent: Int) {
        guard let script = NSAppleScript(source: "set volume alert volume \(percent)") else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}
