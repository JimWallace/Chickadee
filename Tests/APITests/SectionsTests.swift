// Tests/APITests/SectionsTests.swift
//
// Pure-function tests for the v0.4.96 Sections feature:
//   - TestProperties Codable round-trip (new `sections` + per-entry
//     `sectionID` fields; legacy manifests decode unchanged).
//   - buildSuitePayload stamps each emitted row with its entry's
//     sectionID and echoes the ordered section list.
//   - groupOutcomesBySection buckets outcomes in section order with a
//     trailing bucket for unsectioned outcomes.
//
// The heavier integration tests (zip mutation, contiguity enforcement,
// stale-sectionID rewrite, section delete) live in PatternFamilyTests.

import XCTest
@testable import chickadee_server
import Core
import Foundation

final class SectionsTests: XCTestCase {

    // MARK: - TestProperties coding

    func testTestPropertiesRoundTripsWithSectionsAndSectionIDs() throws {
        let props = TestProperties(
            schemaVersion: 1,
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.py", sectionID: "sec-x"),
                TestSuiteEntry(tier: .pub, script: "b.py", sectionID: "sec-y"),
                TestSuiteEntry(tier: .pub, script: "c.py", sectionID: nil),
            ],
            sections: [
                TestSuiteSection(id: "sec-x", name: "Question 1"),
                TestSuiteSection(id: "sec-y", name: "Question 2"),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(props)
        let back = try JSONDecoder().decode(TestProperties.self, from: data)

        XCTAssertEqual(back.sections.map(\.id),   ["sec-x", "sec-y"])
        XCTAssertEqual(back.sections.map(\.name), ["Question 1", "Question 2"])
        XCTAssertEqual(back.testSuites.map(\.sectionID), ["sec-x", "sec-y", nil])
    }

    func testTestPropertiesDecodesLegacyManifestWithNoSectionsField() throws {
        // Manifest shape from before v0.4.96 — no `sections` key, no
        // per-entry sectionID.  Must decode cleanly with empty / nil
        // defaults so the student page and editor behave identically
        // to today's code.
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "requiredFiles": [],
          "testSuites": [
            { "tier": "public", "script": "a.py" },
            { "tier": "public", "script": "b.py" }
          ],
          "timeLimitSeconds": 10,
          "makefile": null,
          "patternFamilies": []
        }
        """
        let props = try JSONDecoder().decode(
            TestProperties.self, from: Data(legacyJSON.utf8)
        )
        XCTAssertTrue(props.sections.isEmpty,
            "Legacy manifest (no `sections` field) must decode to an empty sections array.")
        for entry in props.testSuites {
            XCTAssertNil(entry.sectionID,
                "Legacy entry must decode with sectionID == nil.")
        }
    }

    func testRunnerSanitizedPreservesSectionsAndSectionIDs() {
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.py", sectionID: "s1"),
            ],
            sections: [TestSuiteSection(id: "s1", name: "One")]
        )
        let sanitized = props.runnerSanitized()
        XCTAssertEqual(sanitized.sections.map(\.id), ["s1"])
        XCTAssertEqual(sanitized.testSuites.first?.sectionID, "s1")
        XCTAssertTrue(sanitized.patternFamilies.isEmpty,
            "runnerSanitized must still strip patternFamilies.")
    }

    // MARK: - buildSuitePayload

    func testBuildSuitePayloadEmitsSectionsAndStampsSectionIDs() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.py", sectionID: "s1"),
                TestSuiteEntry(tier: .pub, script: "b.py", sectionID: "s1"),
                TestSuiteEntry(tier: .pub, script: "c.py", sectionID: "s2"),
            ],
            sections: [
                TestSuiteSection(id: "s1", name: "One"),
                TestSuiteSection(id: "s2", name: "Two"),
            ]
        )
        let manifest = String(data: try encoder.encode(props), encoding: .utf8)!

        let payload = buildSuitePayload(fromManifest: manifest)
        XCTAssertEqual(payload.sections.map(\.id),   ["s1", "s2"])
        XCTAssertEqual(payload.sections.map(\.name), ["One", "Two"])
        XCTAssertEqual(payload.items.count, 3)
        XCTAssertEqual(payload.items[0].sectionID, "s1")
        XCTAssertEqual(payload.items[1].sectionID, "s1")
        XCTAssertEqual(payload.items[2].sectionID, "s2")
    }

    func testBuildSuitePayloadLegacyManifestReturnsEmptySections() throws {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "testSuites": [{ "tier": "public", "script": "a.py" }]
        }
        """
        let payload = buildSuitePayload(fromManifest: legacyJSON)
        XCTAssertTrue(payload.sections.isEmpty)
        XCTAssertEqual(payload.items.count, 1)
        XCTAssertNil(payload.items.first?.sectionID)
    }

    // MARK: - groupOutcomesBySection

    private func row(_ testName: String) -> OutcomeRow {
        OutcomeRow(
            testName: testName, tier: "public", status: "pass",
            shortResult: "", longResult: nil,
            markLabel: "Pass", markClass: "pass",
            isSkipped: false, blockerName: nil,
            deltaImproved: false, deltaRegressed: false,
            pointsLabel: nil
        )
    }

    func testGroupOutcomesEmitsSectionsInOrderWithTrailingUngrouped() {
        let sections = [
            TestSuiteSection(id: "s1", name: "One"),
            TestSuiteSection(id: "s2", name: "Two"),
        ]
        let outcomes = [row("a.py"), row("b.py"), row("c.py"), row("d.py")]
        let map: [String: String] = [
            "a.py": "s1",
            "b.py": "s2",
            "c.py": "s1",
            // "d.py" intentionally absent → trailing Ungrouped bucket
        ]
        let grouped = groupOutcomesBySection(outcomes, sections: sections, sectionIDByTestName: map)
        XCTAssertEqual(grouped.count, 3)
        XCTAssertEqual(grouped[0].sectionName, "One")
        XCTAssertEqual(grouped[0].outcomes.map(\.testName), ["a.py", "c.py"])
        XCTAssertEqual(grouped[1].sectionName, "Two")
        XCTAssertEqual(grouped[1].outcomes.map(\.testName), ["b.py"])
        XCTAssertEqual(grouped[2].sectionName, "Ungrouped")
        XCTAssertEqual(grouped[2].outcomes.map(\.testName), ["d.py"])
    }

    func testGroupOutcomesLegacyManifestProducesSingleUnlabelledBucket() {
        let outcomes = [row("a.py"), row("b.py")]
        let grouped = groupOutcomesBySection(outcomes, sections: [], sectionIDByTestName: [:])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertNil(grouped[0].sectionName,
            "Legacy (no sections, no mapping) must render as one unlabelled bucket, identical to the pre-sections page.")
        XCTAssertEqual(grouped[0].outcomes.count, 2)
    }

    func testGroupOutcomesStaleSectionIDFallsThroughToUngrouped() {
        let sections = [TestSuiteSection(id: "s1", name: "One")]
        let outcomes = [row("a.py"), row("b.py")]
        let map = [
            "a.py": "s1",
            "b.py": "s-gone",   // section no longer exists → bucket as ungrouped
        ]
        let grouped = groupOutcomesBySection(outcomes, sections: sections, sectionIDByTestName: map)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].sectionName, "One")
        XCTAssertEqual(grouped[0].outcomes.map(\.testName), ["a.py"])
        XCTAssertEqual(grouped[1].sectionName, "Ungrouped")
        XCTAssertEqual(grouped[1].outcomes.map(\.testName), ["b.py"])
    }

    func testGroupOutcomesEmptyOutcomesStillYieldsOneBucket() {
        // Template loop needs at least one bucket to iterate over;
        // helper returns a single empty bucket on empty input.
        let grouped = groupOutcomesBySection([], sections: [], sectionIDByTestName: [:])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertNil(grouped[0].sectionName)
        XCTAssertTrue(grouped[0].outcomes.isEmpty)
    }
}
