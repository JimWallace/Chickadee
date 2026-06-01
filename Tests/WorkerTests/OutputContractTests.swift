import Core
import Foundation
import Testing

@testable import chickadee_runner

// Native side of the shared output-interpretation contract. Feeds the cases in
// Tests/Fixtures/output-contract.json through interpretScriptOutput and asserts
// the native runner produces the recorded status + display strings. The browser
// side is asserted by Tests/BrowserRunnerJSTests/output-contract.test.mjs, and
// the shared `status` field is what keeps the two runners' GRADING lock-step.
@Suite struct OutputContractTests {

    private struct Corpus: Decodable { let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool?
        let status: String
        let native: Native
    }
    private struct Native: Decodable {
        let shortResult: String
        let longResult: String?
    }

    private func loadCorpus() throws -> Corpus {
        // .../Tests/WorkerTests/OutputContractTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Tests/Fixtures/output-contract.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    @Test func nativeInterpretationMatchesContract() throws {
        for c in try loadCorpus().cases {
            let output = ScriptOutput(
                exitCode: c.exitCode,
                stdout: c.stdout,
                stderr: c.stderr,
                executionTimeMs: 0,
                timedOut: c.timedOut ?? false
            )
            let result = interpretScriptOutput(output)
            #expect(result.status.rawValue == c.status, "status mismatch for case '\(c.name)'")
            #expect(result.shortResult == c.native.shortResult, "shortResult mismatch for case '\(c.name)'")
            #expect(result.longResult == c.native.longResult, "longResult mismatch for case '\(c.name)'")
        }
    }
}
