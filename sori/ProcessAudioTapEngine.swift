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

    /// Mutable state the realtime IOProc block actually touches, isolated
    /// into its own small object so the block never has to capture `self`
    /// (the engine) at all - not `weak self` (every weak load takes the
    /// Swift runtime's global side-table lock, forbidden on this thread),
    /// and deliberately not `unowned(unsafe) self` either: that would rely
    /// on `AudioDeviceStop` having fully drained the IO thread before
    /// `teardown()` can proceed to free the engine, and Apple's own guidance
    /// on the closely related AudioUnit render callback explicitly warns it
    /// "can continue to execute for a short period" after the stop call
    /// returns - exactly the kind of race an unsafe-unowned capture can't
    /// tolerate. Instead, the IOProc block captures `ioState` STRONGLY, and
    /// the engine also holds its own strong reference for the engine's whole
    /// lifetime - so `ioState` can't be deallocated while either the engine
    /// or the still-registered block exists, regardless of exactly when the
    /// last callback fires relative to teardown. See `startIO()`.
    private final class TapIOState {
        // Read on the realtime IO thread, written from wherever the caller
        // lives. Float/Bool load-store is atomic on every architecture this
        // ships on, so plain vars are safe: a torn read would at worst use a
        // one-callback-stale value, never a corrupted one. Do NOT add a lock
        // here - Core Audio's IO thread must never block on a mutex.
        var gain: Float
        /// The gain actually applied as of the end of the previous callback
        /// - the ramp's starting point for the next one. Exclusively
        /// audio-thread-owned (only `process()` reads or writes it - the
        /// external `gain` setter never touches it), so unlike `gain` this
        /// isn't even cross-thread state. Starts equal to the initial
        /// `gain` so the very first callback of a freshly-started tap
        /// applies flat, not ramped in from an arbitrary default - there's
        /// no real "previous" audio to ramp from yet.
        var previousGain: Float
        var limiterEngaged = false

        init(gain: Float) {
            self.gain = gain
            self.previousGain = gain
        }
    }

    private let ioState: TapIOState

    /// Polls `limiterEngaged`/`gain` roughly once a second and logs from the
    /// main thread while boosted - `os_log` can allocate and take locks, so
    /// it must never be called from `process()` on the realtime IO thread
    /// (previously throttled to ~1/100 callbacks there, which only lowered
    /// the probability of a glitch rather than eliminating it). This timer
    /// is the off-thread replacement for that same "Limiter ENGAGED/not
    /// engaged" visibility.
    private var limiterLogTimer: Timer?

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

    /// - Parameters:
    ///   - target: which processes to tap - see `TapTarget`.
    ///   - gain: initial gain factor, clamped to 0.0...2.0.
    ///   - outputDevice: explicit device to render to, overriding the
    ///     default-system-output-device fallback. See `outputDeviceOverride`.
    init(target: TapTarget, gain: Float = 1.0, outputDevice: AudioObjectID? = nil) {
        self.target = target
        self.ioState = TapIOState(gain: Self.clampGain(gain))
        self.outputDeviceOverride = outputDevice
    }

    deinit { teardown() }

    var gain: Float {
        get { ioState.gain }
        set { ioState.gain = Self.clampGain(newValue) }
    }

    /// Read-only from outside - written only by `process()` on the IO
    /// thread, via `ioState`.
    var limiterEngaged: Bool { ioState.limiterEngaged }

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
            startLimiterLogging()
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
        stopLimiterLogging()
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
        // Deliberately captures `ioState` (a plain local `let`, strongly
        // captured) and `tapFormat` only - never `self`. See `TapIOState`'s
        // doc comment for why. `Self.process` is a static function taking
        // both explicitly, so there's no implicit `self` capture hiding in
        // the closure either.
        let state = ioState
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            Self.process(inputData: inInputData, outputData: outOutputData, format: tapFormat, state: state)
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

    // MARK: - Off-thread limiter logging

    /// Scheduled on the main run loop, never the IO thread - see
    /// `limiterLogTimer`'s doc comment.
    private func startLimiterLogging() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.logLimiterStateIfNeeded()
        }
        RunLoop.main.add(t, forMode: .common)
        limiterLogTimer = t
    }

    private func stopLimiterLogging() {
        limiterLogTimer?.invalidate()
        limiterLogTimer = nil
    }

    private func logLimiterStateIfNeeded() {
        let currentGain = gain
        guard currentGain > 1.0 else { return }
        logger.notice("Limiter \(self.limiterEngaged ? "ENGAGED" : "not engaged", privacy: .public) at gain \(currentGain, privacy: .public)")
    }

    /// Runs on the realtime IO thread. No reference to the owning engine
    /// (`self`) at all - see `TapIOState`'s doc comment for why. Ramps from
    /// the gain applied at the end of the previous callback
    /// (`state.previousGain`) to the current target (`state.gain`) linearly
    /// across each buffer's samples, instead of jumping to the target
    /// instantaneously - an unramped per-buffer gain change is classic
    /// zipper noise on any fast change (a slider drag, a mute toggle).
    /// Writes the result into the output buffer list that gets forwarded to
    /// the real output device.
    private static func process(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>, format: AVAudioFormat, state: TapIOState) {
        let inputBufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBufferList = UnsafeMutableAudioBufferListPointer(outputData)

        // Captured ONCE here, not per-buffer/channel - every channel in this
        // callback ramps across the identical start->target pair, so a
        // stereo pair stays in sync, and `previousGain` only advances once,
        // at the very end, after every buffer has been processed with it.
        let startGain = state.previousGain
        let targetGain = state.gain
        // Only boost (gain > 1.0, at either end of the ramp) can push
        // samples outside [-1, 1]; below or at unity throughout, multiplying
        // can only shrink amplitude, so there's nothing to limit and we skip
        // the extra per-sample work entirely.
        let limiterActive = max(startGain, targetGain) > 1.0
        var engagedThisCallback = false

        // Iterate the OUTPUT buffer list, not the input one - Core Audio does
        // not promise output buffers arrive zeroed, and any byte this
        // callback doesn't explicitly write renders whatever stale memory
        // was already there. The previous version iterated `inputBufferList`,
        // which silently skipped (left un-zeroed) any output buffer past the
        // input buffer count, any buffer with a nil `mData`, and any trailing
        // bytes in an output buffer larger than the matching input buffer.
        for (index, outputBuffer) in outputBufferList.enumerated() {
            guard let outputRaw = outputBuffer.mData else { continue }
            let outputByteSize = Int(outputBuffer.mDataByteSize)

            guard index < inputBufferList.count,
                  let inputRaw = inputBufferList[index].mData else {
                memset(outputRaw, 0, outputByteSize)
                continue
            }

            let sampleCount = min(Int(inputBufferList[index].mDataByteSize), outputByteSize) / MemoryLayout<Float32>.size
            guard sampleCount > 0 else {
                memset(outputRaw, 0, outputByteSize)
                continue
            }

            let input = inputRaw.assumingMemoryBound(to: Float32.self)
            let output = outputRaw.assumingMemoryBound(to: Float32.self)

            // Linear ramp from startGain to targetGain across this buffer's
            // own sample count - computed per buffer (not hoisted out of the
            // loop) so a channel with a different frame count this callback
            // (shouldn't normally happen for a synced stereo tap, but not
            // assumed) still ramps correctly against its own length.
            let gainStep = (targetGain - startGain) / Float(sampleCount)
            if limiterActive {
                for sample in 0..<sampleCount {
                    let rampedGain = startGain + gainStep * Float(sample)
                    let boosted = input[sample] * rampedGain
                    let limited = Self.softClip(boosted)
                    if limited != boosted { engagedThisCallback = true }
                    output[sample] = limited
                }
            } else {
                for sample in 0..<sampleCount {
                    let rampedGain = startGain + gainStep * Float(sample)
                    output[sample] = input[sample] * rampedGain
                }
            }

            let writtenByteSize = sampleCount * MemoryLayout<Float32>.size
            if writtenByteSize < outputByteSize {
                memset(outputRaw.advanced(by: writtenByteSize), 0, outputByteSize - writtenByteSize)
            }
        }

        // Advance the ramp baseline for the NEXT callback, once, after every
        // buffer/channel this callback has been processed against the same
        // start/target pair - not `targetGain` re-read per buffer, and not
        // wherever the ramp mathematically landed on the last sample (one
        // step short of `targetGain` by construction), so a steady gain
        // (no further change) starts the next callback flat, not still
        // "chasing" a target it's already effectively reached.
        state.previousGain = targetGain

        if limiterActive {
            // Plain bool write, no logging/allocation here - `os_log` can
            // allocate and take locks, which is why the "Limiter
            // ENGAGED/not engaged" logging itself moved to
            // `logLimiterStateIfNeeded()`, polled from a main-thread timer
            // instead of called from this realtime IO thread.
            state.limiterEngaged = engagedThisCallback
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
}
