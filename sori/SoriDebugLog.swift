import Foundation

/// Millisecond-precision stderr logging for the tap/aggregate/redirect
/// lifecycle, gated behind `SORI_DEBUG_TAP_LIFECYCLE=1`. Exists alongside
/// (not instead of) the normal `Logger` calls scattered through this code
/// because `log stream`/`log show` were confirmed live to be unreliable for
/// this app's own subsystem in this dev environment (see CLAUDE.md) -
/// stderr has been reliable every time. Used specifically for diagnosing
/// rebuild-loop bugs, where the exact sequence and timing of create/destroy
/// calls across files is the whole question.
enum SoriDebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["SORI_DEBUG_TAP_LIFECYCLE"] == "1"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(formatter.string(from: Date()))] \(message())\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}
