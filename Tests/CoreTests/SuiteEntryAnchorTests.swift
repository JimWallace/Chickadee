// Tests/CoreTests/SuiteEntryAnchorTests.swift
//
// A suite entry's pinned anchor (notebook views NB7): it round-trips through
// the manifest codec, it is written only when set, it is rule 1 of the
// anchoring, and the runner never receives it.

import Foundation
import Testing

@testable import Core

@Suite struct SuiteEntryAnchorTests {

    @Test func anAnchorRoundTripsAndIsOmittedWhenUnset() throws {
        let pinned = TestSuiteEntry(tier: .pub, script: "test_a.py", anchor: "average_heart_rate")
        let data = try JSONEncoder().encode(pinned)
        #expect(String(bytes: data, encoding: .utf8)?.contains(#""anchor":"average_heart_rate""#) == true)
        #expect(try JSONDecoder().decode(TestSuiteEntry.self, from: data) == pinned)

        let plain = TestSuiteEntry(tier: .pub, script: "test_a.py")
        #expect(String(bytes: try JSONEncoder().encode(plain), encoding: .utf8)?.contains("anchor") == false)
    }

    @Test func thePinIsRuleOneOfTheAnchoring() throws {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.py", anchor: "summary")], language: .python)
        let entry = try #require(manifest.testSuites.first)
        // The script names `count`, but the pin wins.
        let request = NotebookTestAnchoring.request(for: entry, in: manifest, scriptSource: "assert count(1) == 1")
        #expect(request.pinned == "summary")
        let explicit = NotebookTestAnchoring.request(for: entry, in: manifest, pinned: "other")
        #expect(explicit.pinned == "other")
    }

    @Test func theRunnerNeverReceivesAPin() {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.py", anchor: "summary")], language: .python)
        #expect(manifest.runnerManifest().testSuites.map(\.anchor) == [nil])
        #expect(manifest.testSuites.map(\.anchor) == ["summary"])
    }
}
