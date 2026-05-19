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

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SectionsTests {

    // MARK: - TestProperties coding

    @Test func testPropertiesRoundTripsWithSectionsAndSectionIDs() throws {
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

        #expect(back.sections.map(\.id) == ["sec-x", "sec-y"])
        #expect(back.sections.map(\.name) == ["Question 1", "Question 2"])
        #expect(back.testSuites.map(\.sectionID) == ["sec-x", "sec-y", nil])
    }

    @Test func testPropertiesDecodesLegacyManifestWithNoSectionsField() throws {
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
        #expect(
            props.sections.isEmpty,
            "Legacy manifest (no `sections` field) must decode to an empty sections array.")
        for entry in props.testSuites {
            #expect(entry.sectionID == nil, "Legacy entry must decode with sectionID == nil.")
        }
    }

    @Test func runnerSanitizedPreservesSectionsAndSectionIDs() {
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.py", sectionID: "s1")
            ],
            sections: [TestSuiteSection(id: "s1", name: "One")]
        )
        let sanitized = props.runnerSanitized()
        #expect(sanitized.sections.map(\.id) == ["s1"])
        #expect(sanitized.testSuites.first?.sectionID == "s1")
        #expect(
            sanitized.patternFamilies.isEmpty,
            "runnerSanitized must still strip patternFamilies.")
    }

    // MARK: - buildSuitePayload

    @Test func buildSuitePayloadEmitsSectionsAndStampsSectionIDs() throws {
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
        let manifest = try #require(String(data: try encoder.encode(props), encoding: .utf8))

        let payload = buildSuitePayload(fromManifest: manifest)
        #expect(payload.sections.map(\.id) == ["s1", "s2"])
        #expect(payload.sections.map(\.name) == ["One", "Two"])
        #expect(payload.items.count == 3)
        #expect(payload.items[0].sectionID == "s1")
        #expect(payload.items[1].sectionID == "s1")
        #expect(payload.items[2].sectionID == "s2")
    }

    // Regression for v0.4.157→0.4.158: notebook-check entries in the
    // manifest were emitted by buildSuitePayload as kind:"script" rows,
    // which made the suite-editor drag-and-drop round-trip fail with a
    // bogus "hand-written file already exists" collision.  After the fix
    // they emit as kind:"check" rows carrying the check spec + sectionID.
    @Test func buildSuitePayloadEmitsCheckRowsForNotebookCheckEntries() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let check = NotebookCheck(
            id: "var_exists_x",
            name: "x exists",
            kind: .variableExists,
            tier: .pub,
            points: 2,
            variable: "x"
        )
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "a.py", sectionID: "s1"),
                TestSuiteEntry(
                    tier: .pub,
                    script: "publiccheck_var_exists_x.py",
                    points: 2,
                    generatedByCheck: "var_exists_x",
                    sectionID: nil
                ),
            ],
            notebookChecks: [check],
            sections: [TestSuiteSection(id: "s1", name: "One")]
        )
        let manifest = try #require(String(data: try encoder.encode(props), encoding: .utf8))

        let payload = buildSuitePayload(fromManifest: manifest)
        #expect(payload.items.count == 2)
        #expect(payload.items[0].kind == "script")
        #expect(payload.items[0].sectionID == "s1")
        #expect(payload.items[1].kind == "check")
        #expect(payload.items[1].check?.id == "var_exists_x")
        #expect(payload.items[1].check?.kind == .variableExists)
        #expect(payload.items[1].sectionID == nil)
        // The script's filename must not leak into a check row's script DTO.
        #expect(payload.items[1].script == nil)
    }

    @Test func buildSuitePayloadLegacyManifestReturnsEmptySections() throws {
        let legacyJSON = """
            {
              "schemaVersion": 1,
              "testSuites": [{ "tier": "public", "script": "a.py" }]
            }
            """
        let payload = buildSuitePayload(fromManifest: legacyJSON)
        #expect(payload.sections.isEmpty)
        #expect(payload.items.count == 1)
        #expect(payload.items.first?.sectionID == nil)
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

    @Test func groupOutcomesEmitsSectionsInOrderWithTrailingUngrouped() {
        let sections = [
            TestSuiteSection(id: "s1", name: "One"),
            TestSuiteSection(id: "s2", name: "Two"),
        ]
        let outcomes = [row("a.py"), row("b.py"), row("c.py"), row("d.py")]
        // outcomes[i] → sectionIDPerOutcome[i].  d.py has nil → Ungrouped.
        let perOutcome: [String?] = ["s1", "s2", "s1", nil]
        let grouped = groupOutcomesBySection(outcomes, sections: sections, sectionIDPerOutcome: perOutcome)
        #expect(grouped.count == 3)
        #expect(grouped[0].sectionName == "One")
        #expect(grouped[0].outcomes.map(\.testName) == ["a.py", "c.py"])
        #expect(grouped[1].sectionName == "Two")
        #expect(grouped[1].outcomes.map(\.testName) == ["b.py"])
        #expect(grouped[2].sectionName == "Ungrouped")
        #expect(grouped[2].outcomes.map(\.testName) == ["d.py"])
    }

    @Test func groupOutcomesLegacyManifestProducesSingleUnlabelledBucket() {
        let outcomes = [row("a.py"), row("b.py")]
        let grouped = groupOutcomesBySection(outcomes, sections: [], sectionIDPerOutcome: [nil, nil])
        #expect(grouped.count == 1)
        #expect(
            grouped[0].sectionName == nil,
            "Legacy (no sections, no mapping) must render as one unlabelled bucket, identical to the pre-sections page."
        )
        #expect(grouped[0].outcomes.count == 2)
    }

    @Test func groupOutcomesStaleSectionIDFallsThroughToUngrouped() {
        let sections = [TestSuiteSection(id: "s1", name: "One")]
        let outcomes = [row("a.py"), row("b.py")]
        // outcomes[1] points at a section that's been deleted from the
        // manifest — should bucket as Ungrouped instead of crashing or
        // silently misplacing the row.
        let perOutcome: [String?] = ["s1", "s-gone"]
        let grouped = groupOutcomesBySection(outcomes, sections: sections, sectionIDPerOutcome: perOutcome)
        #expect(grouped.count == 2)
        #expect(grouped[0].sectionName == "One")
        #expect(grouped[0].outcomes.map(\.testName) == ["a.py"])
        #expect(grouped[1].sectionName == "Ungrouped")
        #expect(grouped[1].outcomes.map(\.testName) == ["b.py"])
    }

    @Test func groupOutcomesEmptyOutcomesStillYieldsOneBucket() {
        // Template loop needs at least one bucket to iterate over;
        // helper returns a single empty bucket on empty input.
        let grouped = groupOutcomesBySection([], sections: [], sectionIDPerOutcome: [])
        #expect(grouped.count == 1)
        #expect(grouped[0].sectionName == nil)
        #expect(grouped[0].outcomes.isEmpty)
    }

    /// Regression for the v0.4.105 bug: two pattern families in
    /// different sections used the same case label ("Test 1" in both
    /// `bmi` (Warm Up) and `age` (Warm Up II)).  The old name-keyed
    /// `sectionIDByTestName` collapsed both onto whichever section
    /// got iterated last, so bmi's "Test 1" outcome rendered under
    /// Warm Up II.  Index correlation makes this impossible: the
    /// first "Test 1" outcome lines up with bmi's manifest entry, the
    /// second with age's, even though the displayName is identical.
    @Test func groupOutcomesDistinguishesIdenticalDisplayNamesAcrossSections() {
        let sections = [
            TestSuiteSection(id: "warmup", name: "Warm Up"),
            TestSuiteSection(id: "warmup2", name: "Warm Up II"),
        ]
        let outcomes = [
            row("Test 1"),  // bmi   (Warm Up)
            row("Test 1"),  // age   (Warm Up II)
        ]
        let perOutcome: [String?] = ["warmup", "warmup2"]
        let grouped = groupOutcomesBySection(outcomes, sections: sections, sectionIDPerOutcome: perOutcome)
        #expect(grouped.count == 2)
        #expect(grouped[0].sectionName == "Warm Up")
        #expect(
            grouped[0].outcomes.count == 1,
            "First 'Test 1' outcome must stay in Warm Up — not silently moved by name collision.")
        #expect(grouped[1].sectionName == "Warm Up II")
        #expect(grouped[1].outcomes.count == 1)
    }
}
