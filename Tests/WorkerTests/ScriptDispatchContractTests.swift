import Foundation
import Testing

@testable import chickadee_runner

// Cross-runner script-dispatch contract (worker side).
//
// `scriptInvocation` (Sources/Worker/ScriptInvocation.swift) and the browser
// runner's `classifyScript` (Public/browser-runner.js) are independent
// implementations of the same "how do I run this test script?" rules. They have
// drifted twice in two weeks — most recently extensionless Python scripts being
// reported as unsupported in the browser while the worker ran them fine (#754).
//
// This test pins the worker side to the shared fixture; the browser side is
// pinned to the same fixture by
// Tests/BrowserRunnerJSTests/script-dispatch-contract.test.mjs. Same input ->
// same kind, in both runners.
@Suite struct ScriptDispatchContractTests {

    private struct DispatchCase: Decodable {
        let name: String
        let content: String
        let kind: String
        let note: String
    }

    private struct Fixture: Decodable {
        let cases: [DispatchCase]
    }

    // .../Tests/WorkerTests/ScriptDispatchContractTests.swift -> repo root
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    // Collapse a concrete ScriptInvocation down to the shared vocabulary the
    // browser runner also emits: "python" / "shell" / "r". Other kinds map to
    // "other" so an unexpected match fails loudly against the fixture.
    private func kind(of invocation: ScriptInvocation) -> String {
        let exe = invocation.executableURL.lastPathComponent
        let first = invocation.arguments.first
        if first == "python3" { return "python" }
        if first == "Rscript" { return "r" }
        if exe == "sh" || first == "bash" || first == "zsh" { return "shell" }
        return "other"
    }

    @Test func workerDispatchMatchesSharedContract() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("Tests/Fixtures/script-dispatch-cases.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chickadee-dispatch-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for testCase in fixture.cases {
            let scriptURL = tempDir.appendingPathComponent(testCase.name)
            try testCase.content.write(to: scriptURL, atomically: true, encoding: .utf8)

            let resolved = kind(of: scriptInvocation(for: scriptURL))
            #expect(
                resolved == testCase.kind,
                """
                Dispatch contract violated for "\(testCase.name)" (\(testCase.note)): worker \
                scriptInvocation produced "\(resolved)" but the shared fixture \
                (Tests/Fixtures/script-dispatch-cases.json) requires "\(testCase.kind)". If you \
                changed the rules, update both runners (Sources/Worker/ScriptInvocation.swift and \
                Public/browser-runner.js) and the fixture together.
                """)
        }
    }
}
