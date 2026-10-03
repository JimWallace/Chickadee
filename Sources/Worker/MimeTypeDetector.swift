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

    /// Cap on `file`'s captured output. One MIME type is a few dozen bytes.
    private static let outputLimitBytes = 64 * 1024

    /// Spawns through `swift-subprocess` rather than Foundation's `Process`.
    /// This call runs once per submission file, unthrottled and concurrently
    /// with every other job's -- the concurrent-spawn shape behind #1139 and
    /// #1233. Subprocess owns the capture pipe and drains it, so the
    /// hand-rolled close-on-exec pipe, deadline-bounded drain and
    /// `isRunning`/SIGKILL ladder this replaces have nothing left to do.
    ///
    /// `async` for that reason alone: the work is identical, but the spawn
    /// now suspends instead of blocking a cooperative-pool thread.
    func detectMimeType(for fileURL: URL) async throws -> String {
        let run: BoundedRunResult?
        do {
            run = try await runBounded(
                executable: "/usr/bin/file",
                arguments: ["--mime-type", "-b", fileURL.path],
                limits: BoundedRunLimits(
                    timeout: .seconds(Self.timeoutSeconds), outputLimit: Self.outputLimitBytes,
                    teardownGrace: .milliseconds(200)))
        } catch {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }
        guard let run, run.exitCode == 0 else {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }
        let stdout = run.standardOutput
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "application/octet-stream" : trimmed
    }
}
