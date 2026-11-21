// Tests/CoreTests/Manifest/TimeLimitOverrideCodableTests.swift
//
// Per-test time-limit overrides on pattern families, notebook checks and
// suite entries: the round-trips, the absent key, and the precedence.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct TimeLimitOverrideCodableTests: ISO8601CodingSuite {

    @Test func patternDefaultsTimeLimitRoundTrip() throws {
        let defaults = PatternDefaults(timeLimitSeconds: 30)
        let decoded = try decoder.decode(PatternDefaults.self, from: encoder.encode(defaults))
        #expect(decoded.timeLimitSeconds == 30)
    }

    @Test func patternDefaultsWithoutTimeLimitDecodesNil() throws {
        let json = #"{ "tier": "public", "points": 1 }"#
        let decoded = try decoder.decode(PatternDefaults.self, from: Data(json.utf8))
        #expect(decoded.timeLimitSeconds == nil)
    }

    @Test func patternCaseTimeLimitRoundTrip() throws {
        let c = PatternCase(
            key: "01", label: "slow", args: [.int(1)], expected: .int(1),
            timeLimitSeconds: 120)
        let decoded = try decoder.decode(PatternCase.self, from: encoder.encode(c))
        #expect(decoded.timeLimitSeconds == 120)
    }

    @Test func patternCaseWithoutTimeLimitDecodesNil() throws {
        let json = #"{ "key": "01", "label": "L", "args": [1], "expected": 2 }"#
        let decoded = try decoder.decode(PatternCase.self, from: Data(json.utf8))
        #expect(decoded.timeLimitSeconds == nil)
    }

    @Test func patternCaseResolvedTimeLimitPrecedence() {
        let defaults30 = PatternDefaults(timeLimitSeconds: 30)
        let defaultsNil = PatternDefaults()
        // Case override wins over the family default.
        let withOverride = PatternCase(
            key: "01", label: "L", args: [.int(1)], expected: .int(1), timeLimitSeconds: 120)
        #expect(withOverride.resolvedTimeLimit(defaults: defaults30) == 120)
        // No case override → falls back to the family default.
        let noOverride = PatternCase(key: "02", label: "L", args: [.int(1)], expected: .int(1))
        #expect(noOverride.resolvedTimeLimit(defaults: defaults30) == 30)
        // Neither set → nil (inherit the assignment-wide default).
        #expect(noOverride.resolvedTimeLimit(defaults: defaultsNil) == nil)
    }

    @Test func notebookCheckTimeLimitRoundTrip() throws {
        let check = NotebookCheck(
            id: "df_shape", kind: .dataFrameShape, timeLimitSeconds: 45,
            variable: "df", expectedRows: 1, expectedCols: 1)
        let decoded = try decoder.decode(NotebookCheck.self, from: encoder.encode(check))
        #expect(decoded == check)
        #expect(decoded.timeLimitSeconds == 45)
    }

    @Test func notebookCheckWithoutTimeLimitDecodesNil() throws {
        let json = #"""
            { "id": "c", "kind": "figure_count", "tier": "public", "points": 1, "minFigures": 1 }
            """#
        let decoded = try decoder.decode(NotebookCheck.self, from: Data(json.utf8))
        #expect(decoded.timeLimitSeconds == nil)
    }

    @Test func notebookCheckEqualityLegacyManifestDecodesCleanly() throws {
        // Pre-equality manifests don't carry the new fields; decode must
        // leave them nil rather than throwing.
        let json = """
            {
              "id": "x",
              "kind": "data_frame_equality",
              "tier": "public",
              "points": 1,
              "variable": "df",
              "expectedCSV": "a,b\\n1,2\\n"
            }
            """
        let decoded = try decoder.decode(NotebookCheck.self, from: Data(json.utf8))
        #expect(decoded.checkDtype == nil)
        #expect(decoded.checkLike == nil)
        #expect(decoded.rtol == nil)
        #expect(decoded.atol == nil)
        #expect(decoded.ignoreIndex == nil)
    }

    @Test func testSuiteEntryIsGeneratedReportsBothGenerators() throws {
        let raw = TestSuiteEntry(tier: .pub, script: "manual.py")
        let family = TestSuiteEntry(
            tier: .pub, script: "publictest_bmi_01.py",
            generatedBy: "bmi"
        )
        let check = TestSuiteEntry(
            tier: .pub, script: "publiccheck_df_shape.py",
            generatedByCheck: "df_shape"
        )
        #expect(raw.isGenerated == false)
        #expect(family.isGenerated == true)
        #expect(check.isGenerated == true)
    }

    @Test func testSuiteEntryTimeLimitRoundTripsWhenPresent() throws {
        let entry = TestSuiteEntry(tier: .pub, script: "slow.py", timeLimitSeconds: 45)
        let data = try encoder.encode(entry)
        // The synthesized encode must emit the field.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"timeLimitSeconds\":45"))
        let decoded = try decoder.decode(TestSuiteEntry.self, from: data)
        #expect(decoded.timeLimitSeconds == 45)
    }

    @Test func testSuiteEntryTimeLimitAbsentDecodesToNil() throws {
        // Back-compat: an entry with no timeLimitSeconds key decodes to nil
        // (inherit the assignment default).
        let entry = try decoder.decode(
            TestSuiteEntry.self,
            from: Data(#"{ "tier": "public", "script": "a.py" }"#.utf8))
        #expect(entry.timeLimitSeconds == nil)
        // And a round-trip of the nil case stays nil.
        let reencoded = try encoder.encode(entry)
        let decoded = try decoder.decode(TestSuiteEntry.self, from: reencoded)
        #expect(decoded.timeLimitSeconds == nil)
    }

    @Test func legacyManifestWithoutNotebookChecksDecodesAsEmpty() throws {
        // Pre-NotebookCheck manifests don't carry the notebookChecks field;
        // decoder must default to [].
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(
                """
                { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 10 }
                """.utf8))
        #expect(manifest.notebookChecks.isEmpty)
    }
}
