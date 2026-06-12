import Foundation
import Testing

@testable import APIServer

// Parser side of the dependency-skip-message contract. `parseSkip` (server
// results view) must round-trip the exact wording the runners produce. Pinning
// it to the shared fixture means that if the producer wording changes, this
// test fails until the parser is updated to match — closing the producer/parser
// drift gap. The other parser (SKIP_RE in notebook.js) is asserted JS-side.
@Suite struct DependencySkipParseTests {

    private struct Fixture: Decodable {
        let prerequisite: String
        let message: String
        let parsedBlockerName: String
    }

    private func loadFixture() throws -> Fixture {
        // .../Tests/APITests/DependencySkipParseTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Tests/Fixtures/dependency-skip-message.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func parserRoundTripsSharedFixture() throws {
        let fixture = try loadFixture()
        let result = parseSkip(shortResult: fixture.message)
        #expect(
            result.isSkipped,
            """
            parseSkip no longer recognises the canonical dependency-skip wording from \
            Tests/Fixtures/dependency-skip-message.json — the producer wording and this parser \
            have drifted. Re-sync the prefix/suffix in SubmissionOutputFormatting.parseSkip.
            """)
        #expect(result.blockerName == fixture.parsedBlockerName)
    }
}
