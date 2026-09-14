// Tests/APITests/FailureDetailMaskingTests.swift
//
// `maskFailureOutput` — the display-time application of a suite entry's
// `FailureDetail`. Pins the fail-closed shape: `.actualOnly` keeps only the
// student-side labels and a recognised headline, `.verdictOnly` keeps nothing
// but the verdict, `.full` is a pass-through.

import Core
import Testing

@testable import APIServer

@Suite struct FailureDetailMaskingTests {

    private let pythonLong = """
        stdout:
        wrong value
          input:    classify(3)
          expected: 'ANSWER'
          got:      'GUESS'
        """

    @Test func fullIsAPassThrough() {
        let masked = maskFailureOutput(
            shortResult: "Case 1: wrong value", longResult: pythonLong, status: .fail, detail: .full)
        #expect(masked.shortResult == "Case 1: wrong value")
        #expect(masked.longResult == pythonLong)
    }

    @Test func verdictOnlyKeepsNothingButTheVerdict() {
        for (status, verdict) in [(TestStatus.fail, "did not pass"), (.error, "error"), (.timeout, "timed out")] {
            let masked = maskFailureOutput(
                shortResult: "Case 1: wrong value", longResult: pythonLong, status: status,
                detail: .verdictOnly)
            #expect(masked.shortResult == verdict)
            #expect(masked.longResult == nil)
        }
    }

    @Test func actualOnlyKeepsTheHeadlineInputAndGotButNotExpected() {
        let masked = maskFailureOutput(
            shortResult: "Case 1: wrong value", longResult: pythonLong, status: .fail, detail: .actualOnly)
        // The headline comes from the fuller copy (the long text), which
        // carries no test-label prefix.
        #expect(masked.shortResult == "wrong value")
        let body = masked.longResult ?? ""
        #expect(body.contains("input:"))
        #expect(body.contains("got:      'GUESS'"))
        #expect(!body.contains("expected"))
        #expect(!body.contains("ANSWER"))
    }

    @Test func actualOnlyReadsTheFooterCopyWhenThereIsNoLongResult() {
        // R / Lua / Octave / C++ / Java carry the whole message in shortResult.
        let short = "wrong output\n  input:    f(2)\n  expected: \"ANSWER\"\n  got:      \"GUESS\""
        let masked = maskFailureOutput(
            shortResult: short, longResult: nil, status: .fail, detail: .actualOnly)
        #expect(masked.shortResult == "wrong output")
        #expect(masked.longResult?.contains("GUESS") == true)
        #expect(masked.longResult?.contains("ANSWER") == false)
    }

    @Test func actualOnlyKeepsAMultiLineGotValueWhole() {
        let long = """
            wrong value
              expected: [1,
                         2]
              got:      [1,
                         3]
            """
        let masked = maskFailureOutput(
            shortResult: "wrong value", longResult: long, status: .fail, detail: .actualOnly)
        #expect(masked.longResult == "  got:      [1,\n             3]")
    }

    @Test func actualOnlyWithholdsThresholdDeltaAndMissing() {
        let long = """
            value outside tolerance
              expected:  3.14
              got:       3.0
              delta:     0.14
              budget:    100ms
              took:      212ms
              missing:   ['x']
            """
        let masked = maskFailureOutput(
            shortResult: "value outside tolerance", longResult: long, status: .fail,
            detail: .actualOnly)
        let body = masked.longResult ?? ""
        #expect(body.contains("got:"))
        #expect(body.contains("took:"))
        #expect(!body.contains("delta"))
        #expect(!body.contains("budget"))
        #expect(!body.contains("missing"))
        #expect(!body.contains("expected"))
    }

    @Test func actualOnlyDegradesAHandWrittenScriptToTheVerdict() {
        // A first line nobody recognises could be "expected 42, got 7", so
        // the whole message is withheld and only the verdict shows.
        let masked = maskFailureOutput(
            shortResult: "expected 42, got 7", longResult: "stderr:\nexpected 42, got 7\nTraceback…",
            status: .fail, detail: .actualOnly)
        #expect(masked.shortResult == "did not pass")
        #expect(masked.longResult == nil)
    }

    @Test func actualOnlyDropsATracebackBeforeTheFirstLabel() {
        let long = """
            unexpected exception
            Traceback (most recent call last):
              File "x.py", line 3
              error:    ZeroDivisionError: division by zero
              expected: 4
            """
        let masked = maskFailureOutput(
            shortResult: "unexpected exception", longResult: long, status: .error, detail: .actualOnly)
        #expect(masked.longResult == "  error:    ZeroDivisionError: division by zero")
    }

    @Test func everyStudentSideLabelIsARealLabel() {
        // The allowlist must name labels that exist in the vocabulary group,
        // or a rename there silently starts withholding the student's side.
        let rendered = GeneratedMessage.studentSideLabels.map { GeneratedMessage.standard.label($0) }
        for (name, label) in zip(GeneratedMessage.studentSideLabels, rendered) {
            #expect(label.trimmingCharacters(in: .whitespaces).hasPrefix("\(name):"))
        }
        #expect(!GeneratedMessage.studentSideLabels.contains("expected"))
    }
}
