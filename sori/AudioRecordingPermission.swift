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

    /// Triggers the system TCC prompt for `kTCCServiceAudioCapture`. Only
    /// actually shows a dialog when `status == .unknown` (no decision on
    /// record yet) - once macOS has recorded ANY decision, `.denied` or
    /// `.authorized`, this silently replays that recorded decision instead of
    /// prompting again, even if the user later toggled the setting off in
    /// System Settings. Callers must check `status` first and route to
    /// `openSystemSettingsPrivacyPane()` instead once it's `.denied` - see
    /// that method's doc comment.
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

    /// Opens System Settings directly to the "Screen & System Audio
    /// Recording" privacy pane - the ONLY remaining path back to `.authorized`
    /// once `status` is `.denied`, since macOS will not show the TCC consent
    /// dialog a second time after any decision is recorded (see `request()`).
    /// `Privacy_ScreenCapture` is the correct anchor even though this
    /// permission is "System Audio Recording," not screen recording - Apple
    /// groups both under the same pane (confirmed via Apple's own support
    /// documentation, "Control access to screen and system audio recording on
    /// Mac"). Note for the caller's UI copy: Apple's own guidance is that
    /// toggling the switch there does not take effect until the app is fully
    /// quit and reopened, not just brought back to the foreground - tell the
    /// user this explicitly rather than leaving them to wonder why the
    /// permission banner didn't immediately disappear.
    func openSystemSettingsPrivacyPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            logger.fault("Failed to construct Privacy_ScreenCapture settings URL")
            return
        }
        NSWorkspace.shared.open(url)
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
