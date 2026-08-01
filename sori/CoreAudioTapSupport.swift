import AudioToolbox

enum TapEngineError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case invalidProcessObject(pid: pid_t)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case missingTapFormat
    case audioFormatCreationFailed
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)

    var description: String {
        switch self {
        case .coreAudio(let context, let status):
            return "Core Audio error reading \(context): \(status)"
        case .invalidProcessObject(let pid):
            return "Could not resolve an audio process object for pid \(pid)"
        case .tapCreationFailed(let status):
            return "AudioHardwareCreateProcessTap failed: \(status)"
        case .aggregateDeviceCreationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed: \(status)"
        case .missingTapFormat:
            return "kAudioTapPropertyFormat did not return a usable stream description"
        case .audioFormatCreationFailed:
            return "Failed to build an AVAudioFormat from the tap's stream description"
        case .ioProcCreationFailed(let status):
            return "AudioDeviceCreateIOProcIDWithBlock failed: \(status)"
        case .startFailed(let status):
            return "AudioDeviceStart failed: \(status)"
        }
    }
}

// Small, purpose-built subset of insidegui/AudioCap's CoreAudioUtils.swift -
// just the property reads this project's tap engine needs.
extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isValid: Bool { self != .unknown }

    static func readDefaultSystemOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.systemObject.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioObjectID.unknown
        )
    }

    static func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        let objectID: AudioObjectID = try AudioObjectID.systemObject.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: .unknown,
            qualifier: pid
        )
        guard objectID.isValid else { throw TapEngineError.invalidProcessObject(pid: pid) }
        return objectID
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    /// Reads `kAudioHardwarePropertyProcessObjectList`: the AudioObjectIDs of
    /// every process Core Audio currently knows about (not OS pids - use
    /// `readProcessPID()` on each to translate).
    static func readProcessObjectList() throws -> [AudioObjectID] {
        try AudioObjectID.systemObject.readProcessObjectList()
    }

    func readProcessObjectList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw TapEngineError.coreAudio("size for process object list", err) }

        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw TapEngineError.coreAudio("data for process object list", err) }

        return value
    }

    /// Reads `kAudioHardwarePropertyDevices`: every device Core Audio
    /// currently knows about, hardware and virtual/aggregate alike.
    /// Confirmed live (CLAUDE.md trap #19): a *private* aggregate device
    /// (our own per-app/per-tap scratch devices) is invisible to OTHER
    /// processes enumerating this property, but IS visible to its own
    /// creating process's enumeration of it - i.e. Sori sees its own
    /// aggregates right here. Manual filtering is required: see
    /// `SoriOwnedAggregateDevices`, which `AvailableAudioDevices.refresh()`
    /// checks every own-created aggregate UID against before publishing this
    /// list. Removing that filter reintroduces a real, previously-shipped
    /// bug - a self-sustaining rebuild loop where every tap's freshly-UUID'd
    /// aggregate looked like a new device to Sori itself.
    static func readDeviceList() throws -> [AudioObjectID] {
        try AudioObjectID.systemObject.readDeviceList()
    }

    func readDeviceList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw TapEngineError.coreAudio("size for device list", err) }

        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw TapEngineError.coreAudio("data for device list", err) }

        return value
    }

    /// Number of streams this device exposes in the given scope - a simple,
    /// reliable way to tell whether a device is usable as an output target
    /// (`kAudioDevicePropertyScopeOutput`, > 0) or input source
    /// (`kAudioDevicePropertyScopeInput`, > 0) without parsing its stream
    /// configuration buffer list.
    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize) == noErr else { return 0 }
        return Int(dataSize) / MemoryLayout<AudioStreamID>.size
    }

    /// True if this device's `kAudioDevicePropertyTransportType` is
    /// `kAudioDeviceTransportTypeAggregate` - the reliable way to confirm
    /// "this is actually an aggregate device," independent of its name.
    /// `OrphanedAggregateSweeper` requires this in addition to a
    /// `Sori-Tap-` name-prefix match before ever destroying anything, so a
    /// user's own real device that happens to share the name prefix can
    /// never be touched.
    var isAggregateDevice: Bool {
        (try? read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) == kAudioDeviceTransportTypeAggregate
    }

    /// Reads `kAudioProcessPropertyPID` for a Core Audio process object.
    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))
    }

    /// Reads `kAudioProcessPropertyBundleID` for a Core Audio process object, if any.
    func readProcessBundleID() -> String? {
        guard let value = try? readString(kAudioProcessPropertyBundleID), !value.isEmpty else { return nil }
        return value
    }

    /// Reads `kAudioProcessPropertyIsRunningOutput` - whether this process is
    /// *currently* rendering audio to an output device (as opposed to having
    /// merely opened an audio stream at some point).
    func readProcessIsRunningOutput() -> Bool {
        (try? read(kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0))) == 1
    }

    func hasProperty(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        return AudioObjectHasProperty(self, &address)
    }

    func isPropertySettable(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }

    @discardableResult
    func write<T>(_ value: T,
                   selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutableValue = value
        return AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &mutableValue)
    }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw TapEngineError.coreAudio("size for \(selector)", err) }

        var value = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else { throw TapEngineError.coreAudio("data for \(selector)", err) }

        return value
    }

    func read<T, Q>(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                     defaultValue: T,
                     qualifier: Q) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0
        var mutableQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size)

        var err = withUnsafeMutablePointer(to: &mutableQualifier) { qptr in
            AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qptr, &dataSize)
        }
        guard err == noErr else { throw TapEngineError.coreAudio("size for \(selector)", err) }

        var value = defaultValue
        err = withUnsafeMutablePointer(to: &mutableQualifier) { qptr in
            withUnsafeMutablePointer(to: &value) { vptr in
                AudioObjectGetPropertyData(self, &address, qualifierSize, qptr, &dataSize, vptr)
            }
        }
        guard err == noErr else { throw TapEngineError.coreAudio("data for \(selector)", err) }

        return value
    }

    func readString(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        let cfValue: CFString = try read(selector, scope: scope, element: element, defaultValue: "" as CFString)
        return cfValue as String
    }
}
