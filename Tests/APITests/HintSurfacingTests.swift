// Tests/APITests/HintSurfacingTests.swift
//
// PR2 (v0.4.229): instructor hints are surfaced at results-display time as a
// "💡 Hint" callout on failing tests, replacing the hint text pattern-family
// scripts used to bake into their output.  `buildHintByFilename` is the join
// that maps each generated/raw test filename to its hint; this exercises that
// keying for all three test-item flavours (family case, notebook check, raw
// script) plus the no-hint cases.

import Core
import Testing

@testable import APIServer

@Suite struct HintSurfacingTests {

    @Test func buildHintByFilename_mapsFamilyCaseCheckAndScriptHints() {
        let family = PatternFamily(
            id: "bmi", name: "BMI", kind: .boundaryEquality, functionName: "classify_bmi",
            paramNames: ["bmi"],
            defaults: PatternDefaults(tier: .pub, points: 1),
            cases: [
                PatternCase(
                    key: "01", label: "low", args: [.double(18.49)],
                    expected: .string("underweight"), hint: "mind the 18.5 boundary"),
                PatternCase(
                    key: "02", label: "no hint", args: [.double(22.0)],
                    expected: .string("normal")),
            ])
        let check = NotebookCheck(
            id: "shape", kind: .dataFrameShape, tier: .pub,
            hint: "the grouped frame should have 13 columns",
            variable: "df", expectedRows: 250, expectedCols: 13)
        let rawWithHint = TestSuiteEntry(
            tier: .pub, script: "publictest_raw.py", hint: "read the function docstring")
        let rawNoHint = TestSuiteEntry(tier: .pub, script: "publictest_bare.py")

        let props = TestProperties(
            testSuites: [rawWithHint, rawNoHint],
            patternFamilies: [family],
            notebookChecks: [check])

        let map = buildHintByFilename(props)

        // Family case 01 hint — keyed by the generated filename AND its stem,
        // so it matches both browser (filename) and worker (stem) outcomes.
        #expect(map["publictest_bmi_01.py"] == "mind the 18.5 boundary")
        #expect(map["publictest_bmi_01"] == "mind the 18.5 boundary")
        // Case 02 has no hint → absent.
        #expect(map["publictest_bmi_02.py"] == nil)
        // Check hint — keyed by the check's generated `.py` filename + stem.
        #expect(map["publiccheck_shape.py"] == "the grouped frame should have 13 columns")
        #expect(map["publiccheck_shape"] == "the grouped frame should have 13 columns")
        // Raw-script hint lives on the suite entry.
        #expect(map["publictest_raw.py"] == "read the function docstring")
        #expect(map["publictest_raw"] == "read the function docstring")
        // Raw script without a hint → absent.
        #expect(map["publictest_bare.py"] == nil)
    }

    @Test func buildHintByFilename_emptyWhenNoHintsAuthored() {
        let family = PatternFamily(
            id: "bmi", name: "BMI", kind: .boundaryEquality, functionName: "f",
            paramNames: ["x"],
            defaults: PatternDefaults(tier: .pub, points: 1),
            cases: [
                PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))
            ])
        let props = TestProperties(patternFamilies: [family])
        #expect(buildHintByFilename(props).isEmpty)
    }
}
