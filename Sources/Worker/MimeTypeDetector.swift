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
    func detectMimeType(for fileURL: URL) async throws(SubmissionNormalizationError) -> String {
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
        return Self.mimeType(fromOutput: run.standardOutput)
    }

    /// How many paths one batched `file` run is given. Bounds the argument
    /// list, which a large zipped project could otherwise push toward the
    /// system limit.
    static let batchSize = 256

    /// The MIME type of each of `fileURLs`, in order, from one `file` run per
    /// `batchSize` files rather than one per file: `file` loads its magic
    /// database on every start, and an upload of many files paid that, and a
    /// spawn, for each one.
    ///
    /// `file -b` prints one line per path, in argument order, and the type it
    /// prints for a path does not depend on the other paths. Each line is
    /// read exactly as `detectMimeType(for:)` reads its whole output. A batch
    /// whose run fails, times out, exits non-zero or prints anything but one
    /// line per path gives nil for each of its files, and the caller asks
    /// `detectMimeType(for:)` for those, which then fails, or not, exactly as
    /// it always did.
    func detectMimeTypes(for fileURLs: [URL]) async -> [String?] {
        var types: [String?] = []
        types.reserveCapacity(fileURLs.count)
        var start = fileURLs.startIndex
        while start < fileURLs.endIndex {
            let end = min(start + Self.batchSize, fileURLs.endIndex)
            let batch = Array(fileURLs[start..<end])
            if let detected = await detectBatch(batch) {
                types += detected.map(Optional.some)
            } else {
                types += Array(repeating: nil, count: batch.count)
            }
            start = end
        }
        return types
    }

    private func detectBatch(_ fileURLs: [URL]) async -> [String]? {
        let run: BoundedRunResult?
        do {
            run = try await runBounded(
                executable: "/usr/bin/file",
                arguments: ["--mime-type", "-b"] + fileURLs.map(\.path),
                limits: BoundedRunLimits(
                    timeout: .seconds(Self.timeoutSeconds),
                    outputLimit: Self.outputLimitBytes + 1024 * fileURLs.count,
                    teardownGrace: .milliseconds(200)))
        } catch {
            return nil
        }
        guard let run, run.exitCode == 0 else { return nil }
        var output = run.standardOutput
        guard output.hasSuffix("\n") else { return nil }
        output.removeLast()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == fileURLs.count else { return nil }
        return lines.map { Self.mimeType(fromOutput: String($0)) }
    }

    /// One file's type from what `file -b` printed for it.
    private static func mimeType(fromOutput output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "application/octet-stream" : trimmed
    }
}
