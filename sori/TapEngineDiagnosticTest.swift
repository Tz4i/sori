import AudioToolbox
import Foundation
import OSLog

/// TEMPORARY: exercises `ProcessAudioTapEngine` against the current
/// default-output process group for a few seconds at gain 0.5, logging the
/// RMS of each incoming (pre-gain) buffer to confirm real, non-zero PCM is
/// actually flowing through the tap. Remove once the engine has a real
/// caller.
///
/// Runs only when SORI_RUN_TAP_TEST=1 is set in the environment, so it never
/// fires during normal menu bar use.
enum TapEngineDiagnosticTest {
    private static let logger = Logger(subsystem: "com.sebastianzapata.sori", category: "TapEngineDiagnosticTest")

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["SORI_RUN_TAP_TEST"] == "1" else { return }

        let shouldExitAfter = ProcessInfo.processInfo.environment["SORI_RUN_TAP_TEST_EXIT"] == "1"
        logger.notice("Starting temporary tap diagnostic test (gain 0.5)")

        do {
            let selfPID = ProcessInfo.processInfo.processIdentifier
            let selfObjectID = try AudioObjectID.translatePIDToProcessObjectID(pid: selfPID)

            let engine = ProcessAudioTapEngine(target: .allExcluding([selfObjectID]), gain: 0.5)

            var callbackCount = 0
            engine.rmsHandler = { rms in
                callbackCount += 1
                logger.notice("RMS[\(callbackCount, privacy: .public)] = \(rms, privacy: .public)")
            }

            try engine.start()
            logger.notice("Tap engine started; format = \(String(describing: engine.tapFormat), privacy: .public)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                engine.stop()
                logger.notice("Tap diagnostic test finished after \(callbackCount, privacy: .public) callbacks; engine stopped")
                if shouldExitAfter { exit(0) }
            }
        } catch {
            logger.error("Tap diagnostic test failed: \(String(describing: error), privacy: .public)")
            if shouldExitAfter { exit(1) }
        }
    }
}
