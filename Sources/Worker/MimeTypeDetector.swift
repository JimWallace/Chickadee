import Core
import Foundation
import Subprocess
import SystemPackage

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
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [
            .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .milliseconds(200))
        ]
        let platformOptions = options
        let path = fileURL.path

        let outcome: DetectOutcome
        do {
            outcome = try await withThrowingTaskGroup(of: DetectOutcome.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path("/usr/bin/file"),
                        arguments: ["--mime-type", "-b", path],
                        platformOptions: platformOptions,
                        output: .string(limit: Self.outputLimitBytes)
                    )
                    return .finished(
                        stdout: result.standardOutput,
                        succeeded: result.terminationStatus.isSuccess
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.timeoutSeconds))
                    return .timedOut
                }
                let first = try await group.next()
                // Cancelling the run task tears `file` down; cancelling the
                // sleep merely ends it. Drain so the cancelled sibling's error
                // cannot surface as this call's result.
                group.cancelAll()
                while (try? await group.next()) != nil {}
                return first ?? .timedOut
            }
        } catch {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }

        guard case .finished(let stdout, true) = outcome else {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "application/octet-stream" : trimmed
    }

    /// Which of the two racers finished first.  A flat enum so the task group
    /// has one concrete element type to be generic over.
    private enum DetectOutcome: Sendable {
        case finished(stdout: String, succeeded: Bool)
        case timedOut
    }
}
