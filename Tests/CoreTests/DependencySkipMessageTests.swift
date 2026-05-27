import Foundation
import Testing

@testable import Core

// Producer side of the dependency-skip-message contract. The two grading
// runners both emit this exact string when a test is auto-failed because a
// `dependsOn` prerequisite did not pass: the native worker (via
// `skippedPrerequisiteMessage`, asserted here) and the browser runner
// (Public/browser-runner.js, asserted by Tests/BrowserRunnerJSTests/
// browser-runner.test.mjs). Pinning both producers to the shared fixture means
// a wording change on one side can't silently diverge from the other — or from
// the parsers that read it back (parseSkip / notebook.js).
@Suite struct DependencySkipMessageTests {

    private struct Fixture: Decodable {
        let prerequisite: String
        let message: String
        let parsedBlockerName: String
    }

    private func loadFixture() throws -> Fixture {
        // .../Tests/CoreTests/DependencySkipMessageTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Tests/Fixtures/dependency-skip-message.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func producerMatchesSharedFixture() throws {
        let fixture = try loadFixture()
        #expect(
            skippedPrerequisiteMessage(prerequisite: fixture.prerequisite) == fixture.message,
            """
            skippedPrerequisiteMessage drifted from Tests/Fixtures/dependency-skip-message.json. \
            If you change the wording, update the fixture AND the browser runner producer \
            (Public/browser-runner.js) AND both parsers (parseSkip in SubmissionOutputFormatting, \
            SKIP_RE in notebook.js) together.
            """)
    }
}
