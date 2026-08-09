import Core
import Foundation

#if os(Linux)
import Glibc
#endif

struct MimeTypeDetector {
    /// Ceiling on one `file` invocation. Typically single-digit milliseconds;
    /// the bound exists so a leaked pipe descriptor or a wedged `file` can
    /// pin the calling cooperative-pool thread for at most this long instead
    /// of forever (issue #1233 — this call runs once per submission file per
    /// job, unthrottled, so an unbounded stall here can saturate the whole
    /// pool under parallel-test load).
    private static let timeoutSeconds: TimeInterval = 30

    func detectMimeType(for fileURL: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        // CLOEXEC: without it, any subprocess spawned concurrently with this
        // one inherits a duplicate of the write end across its exec, and the
        // drain below then never sees EOF until that unrelated process exits
        // (the #1139 mechanism, recurring in #1233).
        setCloseOnExec(stdout)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = ["--mime-type", "-b", fileURL.path]
        process.standardOutput = stdout
        try process.run()
        // Drain stdout BEFORE waiting: read-after-wait deadlocks once the
        // child fills the pipe buffer, while EOF arrives exactly when the
        // child exits (docs/ci-flakiness.md, remaining attack order). The
        // drain is deadline-bounded — never an unbounded blocking read on a
        // cooperative-pool thread (issue #1233).
        let data = boundedReadToEOF(
            fromDescriptor: stdout.fileHandleForReading.fileDescriptor,
            deadline: Date().addingTimeInterval(Self.timeoutSeconds)
        )
        if process.isRunning {
            // Deadline hit with `file` still alive: kill it so the reap below
            // cannot block past the bound. SIGKILL cannot be ignored.
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "application/octet-stream"
    }
}
