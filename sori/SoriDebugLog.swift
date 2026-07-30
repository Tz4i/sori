import Foundation

/// Timestamped lifecycle logging for the tap/aggregate/redirect/poll code
/// paths - every tap create/destroy, IOProc start/stop, device-list change,
/// and rebuild trigger already funnels through here (see call sites in
/// `ProcessAudioTapEngine`, `AppVolumeController`, `AvailableAudioDevices`,
/// `AudioProcessMonitor`).
///
/// Always writes to a persistent file, `~/Library/Logs/Sori/sori.log`, not
/// just stderr - a stderr-only log is invisible once the app is launched
/// normally (via Finder/login item, no attached terminal), so it was useless
/// for catching an *unanticipated* crash during ordinary use. Since a crash
/// can't be predicted in advance, this can't be opt-in either: it runs
/// unconditionally so the last lines before any future crash timestamp are
/// always there to read. `SORI_DEBUG_TAP_LIFECYCLE=1` additionally mirrors
/// every line to stderr in real time, for interactive debugging - `log
/// stream`/`log show` were confirmed live to be unreliable for this app's own
/// subsystem in this dev environment (see CLAUDE.md), stderr was reliable
/// every time.
///
/// Every call site so far runs on the main actor (confirmed: the realtime
/// Core Audio IOProc callback in `ProcessAudioTapEngine.process(...)` never
/// calls this) - synchronous file I/O here is fine. A future call site added
/// to that realtime callback would violate CLAUDE.md's realtime-thread rules
/// regardless of what this logger does, so this is not re-checked per-call.
enum SoriDebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["SORI_DEBUG_TAP_LIFECYCLE"] == "1"

    // One rotated backup, 5MB cap each - enough history to see what led up to
    // a crash without the file growing unbounded across days of normal use.
    private static let maxFileSize: UInt64 = 5 * 1024 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Full date, not just time-of-day: this file is expected to span many
        // days of normal use between crashes, and needs to line up against a
        // crash report's own full-date timestamp.
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileHandle: FileHandle? = openLogFile()

    static func log(_ message: @autoclosure () -> String) {
        let line = "[\(formatter.string(from: Date()))] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }

        if isEnabled {
            FileHandle.standardError.write(data)
        }
        fileHandle?.write(data)
    }

    private static var logDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Sori", isDirectory: true)
    }

    private static func openLogFile() -> FileHandle? {
        guard let directory = logDirectory else { return nil }
        let logURL = directory.appendingPathComponent("sori.log")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = (attributes[.size] as? NSNumber)?.uint64Value,
               size > maxFileSize {
                let rotatedURL = directory.appendingPathComponent("sori.log.1")
                try? FileManager.default.removeItem(at: rotatedURL)
                try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
            }

            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            return handle
        } catch {
            FileHandle.standardError.write("SoriDebugLog: failed to open \(logURL.path): \(error)\n".data(using: .utf8)!)
            return nil
        }
    }
}
