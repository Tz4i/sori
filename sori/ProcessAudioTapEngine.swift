import AudioToolbox
import AVFAudio
import OSLog

/// Captures system audio via the Core Audio process tap APIs, applies an
/// adjustable gain, and re-renders the result to the real default output
/// device through a private aggregate device.
///
/// NOTE: this intentionally does NOT use AVAudioEngine anywhere. AVAudioEngine
/// has no supported way to run its input node off of a tap-backed aggregate
/// device - it silently keeps pulling from the system default input instead,
/// so wiring one up here would look like it works but never actually receive
/// the tapped audio. All I/O below goes through
/// `AudioDeviceCreateIOProcIDWithBlock` directly on the aggregate device.
/// `AVAudioFormat` (data-only, no engine) is used just to describe the tap's
/// stream format.
final class ProcessAudioTapEngine {
    /// Which processes the tap captures.
    enum TapTarget {
        /// Everything currently producing audio EXCEPT these processes.
        /// Used for the "tap the whole system" diagnostic case, where we
        /// exclude our own process to avoid feedback.
        case allExcluding([AudioObjectID])
        /// ONLY these processes, mixed down into one stereo tap stream - used
        /// for per-app volume control, where a single gain applies uniformly
        /// across every PID a given app currently owns.
        case only([AudioObjectID])
    }

    private let logger = Logger(subsystem: "com.sebastianzapata.sori", category: "ProcessAudioTapEngine")
    /// Short random tag so concurrent engines (multiple apps tapped at once)
    /// are distinguishable in `SoriDebugLog` output.
    private let instanceTag = String(UUID().uuidString.prefix(8))

    private let target: TapTarget

    /// The device the tap's aggregate renders its (gain-adjusted) output to.
    /// `nil` (the default) preserves this engine's original behavior of
    /// following `kAudioHardwarePropertyDefaultSystemOutputDevice` - every
    /// existing caller (per-app volume control at gain != 1.0, the
    /// whole-system diagnostic tap) keeps working unchanged. A non-nil value
    /// is per-app audio redirection (Block B) or the System section's output
    /// boost tap, both of which need to target a specific, explicitly chosen
    /// device rather than whatever the system default happens to be.
    private let outputDeviceOverride: AudioObjectID?

    // Read on the realtime IO thread, written from wherever the caller lives.
    // Float load/store is atomic on every architecture this ships on, so a
    // plain var is safe: a torn read would at worst use a one-callback-stale
    // gain value, never a corrupted one. Do NOT add a lock here - Core Audio's
    // IO thread must never block on a mutex.
    private var _gain: Float

    // Same atomicity reasoning as `_gain`. Set by the IO thread, read from
    // wherever the caller wants to know if the limiter is active; a torn read
    // just means a one-callback-stale answer.
    private(set) var limiterEngaged: Bool = false
    private var limiterLogCallbackCount = 0

    private var tapDescription: CATapDescription?
    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    /// The UID string this engine gave its own aggregate at creation
    /// (`kAudioAggregateDeviceUIDKey`) - registered with
    /// `SoriOwnedAggregateDevices` while the aggregate exists, so
    /// `AvailableAudioDevices` can filter it back out of its own
    /// enumeration. See that registry's doc comment for why this is needed.
    private var aggregateDeviceUID: String?
    private var deviceProcID: AudioDeviceIOProcID?

    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    private(set) var tapFormat: AVAudioFormat?
    private(set) var isRunning = false

    private let ioQueue = DispatchQueue(label: "com.sebastianzapata.sori.tap-io", qos: .userInteractive)

    /// Optional diagnostics hook: called on the realtime IO thread with the
    /// RMS of each incoming (pre-gain) buffer. Same atomicity note as `gain`
    /// applies to reading/writing this from outside.
    var rmsHandler: ((Float) -> Void)?

    /// - Parameters:
    ///   - target: which processes to tap - see `TapTarget`.
    ///   - gain: initial gain factor, clamped to 0.0...2.0.
    ///   - outputDevice: explicit device to render to, overriding the
    ///     default-system-output-device fallback. See `outputDeviceOverride`.
    init(target: TapTarget, gain: Float = 1.0, outputDevice: AudioObjectID? = nil) {
        self.target = target
        self._gain = Self.clampGain(gain)
        self.outputDeviceOverride = outputDevice
    }

    deinit { teardown() }

    var gain: Float {
        get { _gain }
        set { _gain = Self.clampGain(newValue) }
    }

    private static func clampGain(_ value: Float) -> Float {
        min(max(value, 0.0), 2.0)
    }

    /// Builds the tap + private aggregate device and starts IO. Safe to call
    /// again after `stop()`.
    func start() throws {
        SoriDebugLog.log("[\(instanceTag)] start() called, target=\(target), outputDeviceOverride=\(outputDeviceOverride.map(String.init) ?? "nil")")
        guard !isRunning else {
            SoriDebugLog.log("[\(instanceTag)] start() no-op, already running")
            return
        }

        do {
            try prepare()
            try startIO()
            isRunning = true
            SoriDebugLog.log("[\(instanceTag)] start() complete: tap=#\(processTapID) aggregate=#\(aggregateDeviceID)")
        } catch {
            SoriDebugLog.log("[\(instanceTag)] start() FAILED: \(error) - tearing down")
            teardown()
            throw error
        }
    }

    /// Recovery path for the "silent zero-buffer" failure mode: tear
    /// everything down in the exact required order, then rebuild from
    /// scratch.
    func rebuild() throws {
        stop()
        try start()
    }

    /// Tears down IO, the aggregate device, and the process tap - in that
    /// exact order. Reversing this order (e.g. destroying the tap before the
    /// aggregate device that references it) is what causes the next
    /// create-tap call to intermittently succeed but deliver zero-filled
    /// buffers.
    func stop() {
        SoriDebugLog.log("[\(instanceTag)] stop() called (isRunning=\(isRunning))")
        teardown()
        isRunning = false
    }

    private func teardown() {
        SoriDebugLog.log("[\(instanceTag)] teardown() begin: tap=#\(processTapID) aggregate=#\(aggregateDeviceID)")

        if aggregateDeviceID.isValid, let deviceProcID {
            let stopErr = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            SoriDebugLog.log("[\(instanceTag)] AudioDeviceStop(#\(aggregateDeviceID)) -> \(stopErr)")
            if stopErr != noErr { logger.warning("AudioDeviceStop failed: \(stopErr, privacy: .public)") }

            let destroyProcErr = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            SoriDebugLog.log("[\(instanceTag)] AudioDeviceDestroyIOProcID(#\(aggregateDeviceID)) -> \(destroyProcErr)")
            if destroyProcErr != noErr { logger.warning("AudioDeviceDestroyIOProcID failed: \(destroyProcErr, privacy: .public)") }
            self.deviceProcID = nil
        }

        if aggregateDeviceID.isValid {
            let destroyAggErr = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            SoriDebugLog.log("[\(instanceTag)] AudioHardwareDestroyAggregateDevice(#\(aggregateDeviceID)) -> \(destroyAggErr)")
            if destroyAggErr != noErr { logger.warning("AudioHardwareDestroyAggregateDevice failed: \(destroyAggErr, privacy: .public)") }
            aggregateDeviceID = .unknown
        }

        if let aggregateDeviceUID {
            SoriOwnedAggregateDevices.shared.unregister(aggregateDeviceUID)
            self.aggregateDeviceUID = nil
        }

        if processTapID.isValid {
            let destroyTapErr = AudioHardwareDestroyProcessTap(processTapID)
            SoriDebugLog.log("[\(instanceTag)] AudioHardwareDestroyProcessTap(#\(processTapID)) -> \(destroyTapErr)")
            if destroyTapErr != noErr { logger.warning("AudioHardwareDestroyProcessTap failed: \(destroyTapErr, privacy: .public)") }
            processTapID = .unknown
        }

        tapDescription = nil
        tapStreamDescription = nil
        tapFormat = nil
        SoriDebugLog.log("[\(instanceTag)] teardown() end")
    }

    // MARK: - Setup

    private func prepare() throws {
        // Documented trap #1: both convenience initializers set `isExclusive`
        // for us (false for "exclude", true for "only") - do NOT touch
        // `isExclusive` afterward, in either mode, or it silently inverts
        // what the process list means.
        let description: CATapDescription
        switch target {
        case .allExcluding(let excluded):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .only(let included):
            description = CATapDescription(stereoMixdownOfProcesses: included)
        }
        description.uuid = UUID()
        description.isPrivate = true

        // Documented trap #2: without this, the original audio keeps playing
        // out the real device *and* our gain-adjusted copy gets rendered
        // through the aggregate's main sub-device - every sample doubles.
        // `.mutedWhenTapped` mutes the original at the tap point for as long
        // as the tap is running, so the aggregate's output path is the only
        // thing that reaches the speakers. (`.unmuted` would double audio;
        // plain `.muted` would mute it permanently, independent of the tap's
        // running state - neither is what we want.)
        description.muteBehavior = .mutedWhenTapped

        self.tapDescription = description

        var tapID = AudioObjectID.unknown
        let tapErr = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapErr == noErr else {
            SoriDebugLog.log("[\(instanceTag)] AudioHardwareCreateProcessTap FAILED: \(tapErr)")
            throw TapEngineError.tapCreationFailed(tapErr)
        }
        processTapID = tapID
        logger.debug("Created process tap #\(tapID, privacy: .public)")
        SoriDebugLog.log("[\(instanceTag)] AudioHardwareCreateProcessTap -> #\(tapID) muteBehavior=mutedWhenTapped isPrivate=true")

        let streamDescription = try tapID.readTapStreamBasicDescription()
        self.tapStreamDescription = streamDescription

        var mutableStreamDescription = streamDescription
        guard let format = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
            throw TapEngineError.audioFormatCreationFailed
        }
        self.tapFormat = format

        try createAggregateDevice(tapUUID: description.uuid)
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let outputDeviceID: AudioObjectID
        if let outputDeviceOverride, outputDeviceOverride.isValid {
            outputDeviceID = outputDeviceOverride
        } else {
            outputDeviceID = try AudioObjectID.readDefaultSystemOutputDevice()
        }
        let outputDeviceUID = try outputDeviceID.readDeviceUID()
        let aggregateUID = UUID().uuidString

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sori-Tap-\(aggregateUID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    // Documented trap #3: this must be the UUID string we set
                    // on CATapDescription ourselves (`tapUUID`), NOT a value
                    // read back via `kAudioTapPropertyUID` - that property
                    // does not reliably match what
                    // AudioHardwareCreateAggregateDevice expects and produces
                    // a tap-less (silent) aggregate device.
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        SoriDebugLog.log("[\(instanceTag)] AudioHardwareCreateAggregateDevice: mainSubDevice=\(outputDeviceUID) (deviceID=\(outputDeviceID), override=\(outputDeviceOverride != nil))")

        var newAggregateDeviceID = AudioObjectID.unknown
        var err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID)

        if err == kAudioHardwareIllegalOperationError {
            // 1852797029 ('nope' as a FourCharCode) = kAudioHardwareIllegalOperationError:
            // an aggregate device with conflicting state already exists,
            // typically because a previous instance of this engine wasn't
            // torn down cleanly. Tear down and recreate once.
            logger.warning("Aggregate device already exists (kAudioHardwareIllegalOperationError / 1852797029); tearing down and recreating")
            SoriDebugLog.log("[\(instanceTag)] AudioHardwareCreateAggregateDevice -> kAudioHardwareIllegalOperationError, retrying once")
            teardownAggregateOnly()
            err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID)
        }

        guard err == noErr else {
            SoriDebugLog.log("[\(instanceTag)] AudioHardwareCreateAggregateDevice FAILED: \(err)")
            throw TapEngineError.aggregateDeviceCreationFailed(err)
        }

        aggregateDeviceID = newAggregateDeviceID
        aggregateDeviceUID = aggregateUID
        SoriOwnedAggregateDevices.shared.register(aggregateUID)
        logger.debug("Created aggregate device #\(newAggregateDeviceID, privacy: .public)")
        SoriDebugLog.log("[\(instanceTag)] AudioHardwareCreateAggregateDevice -> #\(newAggregateDeviceID) uid=\(aggregateUID) (registered as own)")
    }

    private func teardownAggregateOnly() {
        if aggregateDeviceID.isValid, let deviceProcID {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            self.deviceProcID = nil
        }
        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
    }

    // MARK: - IO

    private func startIO() throws {
        guard let tapFormat else { throw TapEngineError.missingTapFormat }

        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, outOutputData, _ in
            self?.process(inputData: inInputData, outputData: outOutputData, format: tapFormat)
        }

        let createErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, ioQueue, ioBlock)
        guard createErr == noErr, let procID else {
            SoriDebugLog.log("[\(instanceTag)] AudioDeviceCreateIOProcIDWithBlock FAILED: \(createErr)")
            throw TapEngineError.ioProcCreationFailed(createErr)
        }
        self.deviceProcID = procID
        SoriDebugLog.log("[\(instanceTag)] AudioDeviceCreateIOProcIDWithBlock -> ok on aggregate #\(aggregateDeviceID)")

        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else {
            SoriDebugLog.log("[\(instanceTag)] AudioDeviceStart FAILED: \(startErr)")
            throw TapEngineError.startFailed(startErr)
        }
        SoriDebugLog.log("[\(instanceTag)] AudioDeviceStart -> ok on aggregate #\(aggregateDeviceID)")
    }

    /// Runs on the realtime IO thread. Multiplies every sample in the tapped
    /// input by the current gain and writes the result into the output
    /// buffer list that gets forwarded to the real output device.
    private func process(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>, format: AVAudioFormat) {
        let inputBufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBufferList = UnsafeMutableAudioBufferListPointer(outputData)

        if let rmsHandler {
            rmsHandler(Self.rms(of: inputBufferList))
        }

        let currentGain = _gain
        // Only boost (gain > 1.0) can push samples outside [-1, 1]; below or
        // at unity, multiplying can only shrink amplitude, so there's nothing
        // to limit and we skip the extra per-sample work entirely.
        let limiterActive = currentGain > 1.0
        var engagedThisCallback = false

        for (index, inputBuffer) in inputBufferList.enumerated() {
            guard index < outputBufferList.count,
                  let inputRaw = inputBuffer.mData,
                  let outputRaw = outputBufferList[index].mData else { continue }

            let sampleCount = min(Int(inputBuffer.mDataByteSize), Int(outputBufferList[index].mDataByteSize)) / MemoryLayout<Float32>.size
            guard sampleCount > 0 else { continue }

            let input = inputRaw.assumingMemoryBound(to: Float32.self)
            let output = outputRaw.assumingMemoryBound(to: Float32.self)

            if limiterActive {
                for sample in 0..<sampleCount {
                    let boosted = input[sample] * currentGain
                    let limited = Self.softClip(boosted)
                    if limited != boosted { engagedThisCallback = true }
                    output[sample] = limited
                }
            } else {
                for sample in 0..<sampleCount {
                    output[sample] = input[sample] * currentGain
                }
            }
        }

        if limiterActive {
            limiterEngaged = engagedThisCallback
            // Throttled to ~once/second instead of every callback (~100/sec)
            // so this stays cheap on the realtime IO thread while still
            // giving visibility into whether boost is actually hitting the
            // limiter, per the requirement to log this.
            limiterLogCallbackCount += 1
            if limiterLogCallbackCount >= 100 {
                limiterLogCallbackCount = 0
                logger.notice("Limiter \(engagedThisCallback ? "ENGAGED" : "not engaged", privacy: .public) at gain \(currentGain, privacy: .public)")
            }
        }
    }

    /// Soft-knee limiter: transparent (identity) below `softKneeThreshold`,
    /// then smoothly compresses anything above it toward the ±1.0 asymptote
    /// via `tanh` instead of hard-clipping at exactly ±1.0. Only ever called
    /// when gain > 1.0, so normal (unity or attenuated) playback is never
    /// touched by this shaping.
    private static let softKneeThreshold: Float = 0.9

    private static func softClip(_ x: Float) -> Float {
        let absX = abs(x)
        guard absX > softKneeThreshold else { return x }

        let sign: Float = x < 0 ? -1 : 1
        let range = 1 - softKneeThreshold
        let excess = absX - softKneeThreshold
        let compressed = softKneeThreshold + range * Float(tanh(Double(excess / range)))
        return sign * compressed
    }

    private static func rms(of bufferList: UnsafeMutableAudioBufferListPointer) -> Float {
        var sumOfSquares: Float = 0
        var totalSamples = 0

        for buffer in bufferList {
            guard let mData = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            guard sampleCount > 0 else { continue }

            let samples = mData.assumingMemoryBound(to: Float32.self)
            for i in 0..<sampleCount {
                sumOfSquares += samples[i] * samples[i]
            }
            totalSamples += sampleCount
        }

        guard totalSamples > 0 else { return 0 }
        return (sumOfSquares / Float(totalSamples)).squareRoot()
    }
}
