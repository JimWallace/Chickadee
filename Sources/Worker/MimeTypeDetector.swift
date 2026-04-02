import Foundation

struct MimeTypeDetector {
    func detectMimeType(for fileURL: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = ["--mime-type", "-b", fileURL.path]
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SubmissionNormalizationError.mimeDetectionFailed(fileURL.lastPathComponent)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "application/octet-stream"
    }
}
