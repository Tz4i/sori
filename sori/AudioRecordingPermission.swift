import AppKit
import Observation
import OSLog

/// Checks and requests the "System Audio Recording" TCC permission that guards
/// the Core Audio process tap APIs (`AudioHardwareCreateProcessTap` et al.),
/// i.e. `kTCCServiceAudioCapture`.
///
/// This is modeled directly on insidegui/AudioCap's `AudioRecordingPermission`:
/// there is no public API for this permission, so we `dlopen` the private
/// TCC.framework and call `TCCAccessPreflight`/`TCCAccessRequest` for the
/// `kTCCServiceAudioCapture` service via `dlsym`.
///
/// NOTE for future steps: the actual audio capture must go through the Core
/// Audio process tap APIs (`AudioHardwareCreateProcessTap`), NOT `AVAudioEngine`.
/// `AVAudioEngine` has no concept of tapping another process's output and is
/// not part of this permission's flow — do not introduce it here.
@Observable
final class AudioRecordingPermission {
    private let logger = Logger(subsystem: "com.sebastianzapata.sori", category: String(describing: AudioRecordingPermission.self))

    enum Status: String {
        case unknown
        case denied
        case authorized
    }

    private(set) var status: Status = .unknown

    private var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatus()
        }

        updateStatus()
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    /// Triggers the system TCC prompt for `kTCCServiceAudioCapture`, if the OS
    /// hasn't already made a permanent decision for this app.
    func request() {
        logger.debug(#function)

        guard let request = Self.requestSPI else {
            logger.fault("TCCAccessRequest SPI missing")
            return
        }

        request(Self.audioCaptureService, nil) { [weak self] granted in
            guard let self else { return }

            self.logger.info("Request finished with result: \(granted, privacy: .public)")

            DispatchQueue.main.async {
                self.status = granted ? .authorized : .denied
            }
        }
    }

    private func updateStatus() {
        logger.debug(#function)

        guard let preflight = Self.preflightSPI else {
            logger.fault("TCCAccessPreflight SPI missing")
            return
        }

        // TCCAccessPreflight returns a tri-state result: 0 = authorized,
        // 1 = denied, anything else (e.g. -1) = not yet determined.
        let result = preflight(Self.audioCaptureService, nil)

        switch result {
        case 0:
            status = .authorized
        case 1:
            status = .denied
        default:
            status = .unknown
        }
    }

    // MARK: - TCC private SPI plumbing

    private static let audioCaptureService = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    /// `dlopen` handle to the TCC framework.
    private static let apiHandle: UnsafeMutableRawPointer? = {
        let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"

        guard let handle = dlopen(tccPath, RTLD_NOW) else {
            assertionFailure("dlopen of TCC.framework failed")
            return nil
        }

        return handle
    }()

    /// `dlsym` function handle for `TCCAccessPreflight`.
    private static let preflightSPI: PreflightFuncType? = {
        guard let apiHandle else { return nil }
        guard let funcSym = dlsym(apiHandle, "TCCAccessPreflight") else {
            assertionFailure("Couldn't find TCCAccessPreflight symbol")
            return nil
        }
        return unsafeBitCast(funcSym, to: PreflightFuncType.self)
    }()

    /// `dlsym` function handle for `TCCAccessRequest`.
    private static let requestSPI: RequestFuncType? = {
        guard let apiHandle else { return nil }
        guard let funcSym = dlsym(apiHandle, "TCCAccessRequest") else {
            assertionFailure("Couldn't find TCCAccessRequest symbol")
            return nil
        }
        return unsafeBitCast(funcSym, to: RequestFuncType.self)
    }()
}
