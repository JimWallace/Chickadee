// Write-side hygiene guard for the admin query_logs ring buffer.
//
// RingBufferLogHandler captures every warning+ log event process-wide and
// redacts known PII metadata KEYS — but message strings are stored verbatim.
// The write-side convention is therefore: identifiers (usernames, user ids,
// submission ids, client IPs) go into metadata under a redacted key, never
// into the message text. This suite scans APIServer sources for
// warning/error/critical logger calls whose message interpolates a known
// identifier variable and fails the build on a match, so the convention
// cannot silently regress (compliance audit F-1; same source-scan technique
// as MCPStudentDataWallTests).

import Foundation
import Testing

@testable import APIServer

@Suite struct LogMessageHygieneTests {
    /// `Sources/APIServer`, resolved from this test file's location.
    private static var apiServerSources: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("Sources/APIServer")
    }

    /// Interpolation fragments that would put an identifier into log MESSAGE
    /// text. Matched against the message portion (before any `metadata:`
    /// label) of a warning/error/critical logger call — the call line plus a
    /// few continuation lines, since messages often wrap.
    private static let forbiddenMessageFragments = [
        #"\(username"#, #"\(usernameKey"#, #"\(ip)"#, #"\(userID)"#,
        #"submission=\("#, #"for user \("#, #"user '\("#, #"\(orgDefinedId"#,
    ]

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func warningPlusLogMessagesInterpolateNoIdentifiers() throws {
        let files = try swiftFiles(under: Self.apiServerSources)
        #expect(!files.isEmpty)  // sanity: the directory resolved

        let callPattern = try NSRegularExpression(
            pattern: #"logger\s*\.\s*(warning|error|critical)\s*\("#)

        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard callPattern.firstMatch(in: line, options: [], range: range) != nil
                else { continue }
                // The message argument comes before any `metadata:` label;
                // metadata may carry identifiers freely (the ring buffer
                // redacts those keys at capture).
                let window = lines[index..<min(index + 4, lines.count)]
                    .joined(separator: "\n")
                let message = window.components(separatedBy: "metadata:").first ?? window
                for fragment in Self.forbiddenMessageFragments {
                    #expect(
                        !message.contains(fragment),
                        """
                        \(file.lastPathComponent):\(index + 1) interpolates an identifier \
                        (\(fragment)) into a warning+ log MESSAGE. The admin query_logs ring \
                        buffer stores message text verbatim — move the identifier into \
                        structured metadata under a key in RingBufferLogHandler.piiKeys so it \
                        is redacted at capture (console logging keeps full fidelity).
                        """)
                }
            }
        }
    }
}
