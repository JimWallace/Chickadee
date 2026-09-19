// Tests/APITests/FailureDetailApplyTests.swift
//
// `FailureDetail` through the apply path: a raw script's setting persists
// and survives a re-apply, a family default and a per-case value land on the
// generated entries (guard included), a check's value lands on its entry,
// and `.full` is never written to the manifest.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct FailureDetailApplyTests {

    @Test func rawScriptSettingPersistsAndSurvivesReapply() async throws {
        try await withPatternFamilyFixture { fixture in
            try await updateScriptInZip(
                zipPath: fixture.setup.zipPath, filename: "publictest_masked.py",
                content: "# masked\npassed('ok')\n")
            let rawEntry = AuthoredRawScript(
                script: "publictest_masked.py", tier: .pub, points: 1, displayName: nil,
                dependsOn: [], failureDetail: .actualOnly)
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()],
                authoredItems: [.script(rawEntry), .family(id: "bmi_category")],
                on: fixture.app.db)

            let props = try pfDecodeManifest(fixture.setup.manifest)
            let masked = try #require(props.testSuites.first { $0.script == "publictest_masked.py" })
            #expect(masked.failureDetail == .actualOnly)
            #expect(fixture.setup.manifest.contains("\"failureDetail\":\"actualOnly\""))

            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: props.patternFamilies, on: fixture.app.db)
            let reapplied = try pfDecodeManifest(fixture.setup.manifest)
            let after = try #require(reapplied.testSuites.first { $0.script == "publictest_masked.py" })
            #expect(after.failureDetail == .actualOnly, "must survive an authoredItems==nil re-apply")
        }
    }

    @Test func familyDefaultAndPerCaseValuePropagateToGeneratedEntries() async throws {
        try await withPatternFamilyFixture { fixture in
            var cases = pfBMIFamily().cases
            cases[1] = PatternCase(
                key: cases[1].key, label: cases[1].label, args: cases[1].args,
                expected: cases[1].expected, failureDetail: .verdictOnly)
            let family = PatternFamily(
                id: "bmi_category", name: "BMI", kind: .boundaryEquality,
                functionName: "bmi_category", paramNames: ["bmi"],
                defaults: PatternDefaults(tier: .pub, points: 1, failureDetail: .actualOnly),
                cases: cases)
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [family], on: fixture.app.db)

            let props = try pfDecodeManifest(fixture.setup.manifest)
            let generated = props.testSuites.filter { $0.generatedBy == "bmi_category" }
            #expect(generated.count == 4, "three cases plus the existence guard")
            let byKey = Dictionary(uniqueKeysWithValues: generated.map { ($0.script, $0.failureDetail) })
            #expect(byKey["publictest_bmi_category_01.py"] == .actualOnly)
            #expect(byKey["publictest_bmi_category_02.py"] == .verdictOnly, "the per-case value wins")
            #expect(byKey["publictest_bmi_category_03.py"] == .actualOnly)
            #expect(byKey["publictest_bmi_category_exists.py"] == .actualOnly, "the guard takes the default")
        }
    }

    @Test func fullIsNeverWrittenToTheManifest() async throws {
        try await withPatternFamilyFixture { fixture in
            let family = PatternFamily(
                id: "bmi_category", name: "BMI", kind: .boundaryEquality,
                functionName: "bmi_category", paramNames: ["bmi"],
                defaults: PatternDefaults(tier: .pub, points: 1, failureDetail: .full),
                cases: pfBMIFamily().cases)
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [family], on: fixture.app.db)
            // The generated entries carry no key for the default, so a suite
            // reset to full reads exactly as one that predates the field.
            let props = try pfDecodeManifest(fixture.setup.manifest)
            for entry in props.testSuites where entry.generatedBy == "bmi_category" {
                #expect(entry.failureDetail == nil, "\(entry.script) must not record full")
            }
            let entriesJSON = try #require(
                fixture.setup.manifest.range(of: "\"testSuites\":").map {
                    String(fixture.setup.manifest[$0.upperBound...])
                })
            #expect(!entriesJSON.prefix(while: { $0 != "]" }).contains("failureDetail"))
        }
    }

    @Test func notebookCheckValuePropagatesToItsEntry() async throws {
        try await withPatternFamilyFixture { fixture in
            let check = NotebookCheck(
                id: "shape", kind: .dataFrameShape, tier: .pub, failureDetail: .verdictOnly,
                variable: "df", expectedRows: 3, expectedCols: 2)
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [], nextChecks: [check],
                authoredItems: [.check(id: "shape", sectionID: nil)], on: fixture.app.db)
            let props = try pfDecodeManifest(fixture.setup.manifest)
            let entry = try #require(props.testSuites.first { $0.generatedByCheck == "shape" })
            #expect(entry.failureDetail == .verdictOnly)
        }
    }
}
