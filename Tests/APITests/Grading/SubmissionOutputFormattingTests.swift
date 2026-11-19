// Tests/APITests/Grading/SubmissionOutputFormattingTests.swift
//
// The pure helpers in `Helpers/SubmissionOutputFormatting.swift` that turn a
// script's stdout, stderr and JSON envelope into the strings a student reads.
// `WebRoutesSubmissionPageTests` covers the common envelope through the page;
// these pin the remaining branches directly: the per-status default short
// result, JSON arrays and nested objects, de-duplicated messages, labelled
// `stdout:` / `stderr:` sections and the upload-extension heuristic.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SubmissionOutputFormattingTests {

    // MARK: - parseSkip

    @Test func parseSkipStripsTheExtensionFromTheBlocker() {
        let parsed = parseSkip(shortResult: "Skipped: prerequisite 'test_build.py' did not pass")
        #expect(parsed.isSkipped)
        #expect(parsed.blockerName == "test_build")
    }

    @Test func parseSkipKeepsANameWithNoExtension() {
        let parsed = parseSkip(shortResult: "Skipped: prerequisite 'test_build' did not pass")
        #expect(parsed.isSkipped)
        #expect(parsed.blockerName == "test_build")
    }

    @Test func parseSkipReportsNoBlockerWhenOnlyAnExtensionRemains() {
        let parsed = parseSkip(shortResult: "Skipped: prerequisite '.py' did not pass")
        #expect(parsed.isSkipped)
        #expect(parsed.blockerName == nil)
    }

    @Test func parseSkipRejectsOtherText() {
        let parsed = parseSkip(shortResult: "3/4 cases passed")
        #expect(!parsed.isSkipped)
        #expect(parsed.blockerName == nil)
    }

    // MARK: - formattedShortResult

    @Test(arguments: [
        (TestStatus.pass, "passed"), (.fail, "failed"), (.error, "error"), (.timeout, "timed out"),
    ])
    func emptyOutputGetsTheStatusDefault(_ status: TestStatus, _ expected: String) {
        #expect(formattedShortResult(from: "  \n ", status: status) == expected)
    }

    @Test func aJSONArraySummaryUsesTheFirstNonEmptyEntry() {
        #expect(formattedShortResult(from: #"["", {"message": "boom"}]"#, status: .fail) == "boom")
    }

    @Test func aJSONScalarWithNoTextIsShownVerbatim() {
        #expect(formattedShortResult(from: "42", status: .fail) == "42")
    }

    @Test func aSummaryInsideALabelledSectionIsExtracted() {
        let raw = "stdout:\n{\"message\": \"bad input\"}"
        #expect(formattedShortResult(from: raw, status: .fail) == "bad input")
    }

    @Test func plainTextIsTrimmedAndKept() {
        #expect(formattedShortResult(from: "  2/3 passed \n", status: .fail) == "2/3 passed")
    }

    // MARK: - formattedDetailedOutput

    @Test func aPassingTestHasNoDetailedOutput() {
        #expect(formattedDetailedOutput(primary: "anything", fallback: "else", status: .pass) == nil)
    }

    @Test func theFallbackIsUsedWhenThePrimaryIsBlank() {
        #expect(formattedDetailedOutput(primary: "  ", fallback: "plain error", status: .fail) == "plain error")
        #expect(formattedDetailedOutput(primary: nil, fallback: nil, status: .fail) == nil)
    }

    @Test func aTracebackIsCutFromItsMarker() {
        let raw = "setup log\nTraceback (most recent call last):\n  File \"t.py\"\nValueError: v"
        #expect(
            formattedDetailedOutput(primary: raw, fallback: nil, status: .error)
                == "Traceback (most recent call last):\n  File \"t.py\"\nValueError: v")
    }

    @Test func structuredMessagesAreJoinedAndDeduplicated() {
        let raw = #"{"stderr": "first", "error": "second", "message": "first"}"#
        #expect(formattedDetailedOutput(primary: raw, fallback: nil, status: .fail) == "first\n\nsecond")
    }

    @Test func messagesFromAJSONArrayAreJoinedInOrder() {
        let raw = #"[{"error": "a"}, "b", ""]"#
        #expect(formattedDetailedOutput(primary: raw, fallback: nil, status: .fail) == "a\n\nb")
    }

    @Test func aTracebackNestedUnderAnUnknownKeyIsFound() {
        let raw = #"{"result": {"traceback": "Traceback (most recent call last):\nKeyError: k"}}"#
        #expect(
            formattedDetailedOutput(primary: raw, fallback: nil, status: .error)
                == "Traceback (most recent call last):\nKeyError: k")
    }

    @Test func aTracebackInsideAJSONArrayIsFound() {
        let raw = #"["noise", "PythonError: bad thing"]"#
        #expect(formattedDetailedOutput(primary: raw, fallback: nil, status: .error) == "PythonError: bad thing")
    }

    @Test func aJSONScalarWithNoMessageIsShownVerbatim() {
        #expect(formattedDetailedOutput(primary: "7", fallback: nil, status: .fail) == "7")
    }

    @Test func theSectionWithATracebackWins() {
        let raw = "stdout:\nhello\n\nstderr:\nTraceback (most recent call last):\nboom"
        #expect(
            formattedDetailedOutput(primary: raw, fallback: nil, status: .error)
                == "Traceback (most recent call last):\nboom")
    }

    @Test func aStructuredErrorInStdoutBeatsPlainStderr() {
        let raw = "stderr:\nwarning only\n\nstdout:\n{\"error\": \"real failure\"}"
        #expect(formattedDetailedOutput(primary: raw, fallback: nil, status: .fail) == "real failure")
    }

    @Test func plainStderrIsPreferredOverPlainStdout() {
        let raw = "stdout:\nlog line\n\nstderr:\noops"
        #expect(formattedDetailedOutput(primary: raw, fallback: nil, status: .fail) == "oops")
    }

    // MARK: - formattedPassingDetailedOutput

    @Test func passingOutputPrefersStdoutThenStderrThenTheWholeText() {
        #expect(formattedPassingDetailedOutput(primary: nil) == nil)
        #expect(formattedPassingDetailedOutput(primary: " \n") == nil)
        #expect(formattedPassingDetailedOutput(primary: "stderr:\nwarn\n\nstdout:\nout") == "out")
        #expect(formattedPassingDetailedOutput(primary: "stderr:\nwarn") == "warn")
        #expect(formattedPassingDetailedOutput(primary: "  just text ") == "just text")
    }

    // MARK: - inferredRawSubmissionExtension

    @Test func theUploadFilenameExtensionWinsAndIsLowercased() {
        #expect(inferredRawSubmissionExtension(data: Data("x".utf8), uploadFilename: "Main.PY") == "py")
    }

    @Test func aNotebookIsRecognisedByItsNBFormatKey() {
        let notebook = Data(#"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#.utf8)
        #expect(inferredRawSubmissionExtension(data: notebook, uploadFilename: nil) == "ipynb")
        #expect(inferredRawSubmissionExtension(data: notebook, uploadFilename: "README") == "ipynb")
    }

    @Test func anythingElseIsText() {
        #expect(inferredRawSubmissionExtension(data: Data("print(1)".utf8), uploadFilename: nil) == "txt")
        #expect(inferredRawSubmissionExtension(data: Data(#"{"cells":[]}"#.utf8), uploadFilename: "noext") == "txt")
    }
}
