// Architectural guard for AI-assisted feedback (docs/ai-assisted-feedback.md):
// no MCP source may set either opt-in gate. A person turns the course gate on
// (an admin) and the assignment gate on (an instructor), on the web. If an MCP
// tool could write `aiFeedbackEnabled`, an agent could widen its own reach to
// students' written answers. The `chickadee_mcp` database role keeps UPDATE on
// courses and assignments for authoring, so this scan is the control that
// keeps those two columns out of the agent's reach.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPAIFeedbackGateTests {
    private static var mcpDirectory: URL {
        repositoryRoot.appendingPathComponent("Sources/APIServer/MCP")
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noMCPSourceWritesAnAIFeedbackGate() throws {
        let files = swiftFiles(under: Self.mcpDirectory)
        #expect(files.count > 50)  // sanity: the directory resolved
        let assignment = try Regex(#"aiFeedbackEnabled\s*=[^=]"#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                source.firstMatch(of: assignment) == nil,
                """
                \(file.lastPathComponent) assigns aiFeedbackEnabled. Only the web pages may set the \
                AI-assisted feedback gates; an agent must never widen its own reach to student work.
                """)
        }
    }
}
