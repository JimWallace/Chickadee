import Foundation

struct MimeTypeDetector {
    func detectMimeType(for fileURL: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = ["--mime-type", "-b", fileURL.path]
        process.standardOutput = stdout
        try process.run()
        // Drain stdout BEFORE waiting: read-after-wait deadlocks once the
        // child fills the pipe buffer, while EOF arrives exactly when the
        // child exits (docs/ci-flakiness.md, remaining attack order).
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "application/octet-stream"
    }
}
