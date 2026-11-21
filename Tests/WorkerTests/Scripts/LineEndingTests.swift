import Testing

@testable import RunnerCore

// #1457: "\r\n" is ONE Swift `Character`, so a split on "\n" never split CRLF
// text. A script whose stdout used Windows line endings lost its JSON footer
// (and with it its partial-credit `score`), and an extensionless CRLF Python
// script classified as `.unknown`. These pin the shared `splitLines` and each
// of the three RunnerCore sites the issue names, on the native build; the
// browser runs the same source once the wasm artifact is re-vendored.
@Suite struct LineEndingTests {

    // MARK: - splitLines

    @Test func splitLinesTreatsEveryLineBreakConventionAsOneBreak() {
        #expect(splitLines("a\nb\nc") == ["a", "b", "c"])
        #expect(splitLines("a\r\nb\r\nc") == ["a", "b", "c"])
        #expect(splitLines("a\rb\rc") == ["a", "b", "c"])
        #expect(splitLines("a\r\nb\nc\rd") == ["a", "b", "c", "d"])
    }

    @Test func splitLinesKeepsEmptyLinesAndATrailingBreak() {
        // Same shape as `omittingEmptySubsequences: false`: one more element
        // than there are line breaks, and "" is one empty line.
        #expect(splitLines("") == [""])
        #expect(splitLines("a\n") == ["a", ""])
        #expect(splitLines("a\r\n") == ["a", ""])
        #expect(splitLines("a\r\n\r\nb") == ["a", "", "b"])
        #expect(splitLines("\r\n") == ["", ""])
    }

    @Test func splitLinesDoesNotMergeALoneCRWithAFollowingLF() {
        // "\r" then "\n" IS a CRLF pair; "\n" then "\r" is two breaks.
        #expect(splitLines("a\n\rb") == ["a", "", "b"])
    }

    @Test func isWhitespaceOrLineBreakSeesTheCRLFGrapheme() {
        #expect(isWhitespaceOrLineBreak("\r\n"))
        #expect(isWhitespaceOrLineBreak("\n"))
        #expect(isWhitespaceOrLineBreak("\r"))
        #expect(isWhitespaceOrLineBreak(" "))
        #expect(isWhitespaceOrLineBreak("\t"))
        #expect(!isWhitespaceOrLineBreak("a"))
        #expect(!isWhitespaceOrLineBreak("\u{feff}"))
    }

    // MARK: - interpretScriptOutput

    private func interpret(stdout: String, exitCode: Int32 = 0) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(exitCode: exitCode, stdout: stdout, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    /// The measured defect: the same footer, CRLF instead of LF, used to come
    /// back as the raw stdout with `score` 1.0.
    @Test func aCRLFFooterIsFoundAndItsScoreHonoured() {
        let lf = interpret(stdout: "checking...\n{\"shortResult\":\"3/4 cases passed\",\"score\":0.75}\n")
        let crlf = interpret(stdout: "checking...\r\n{\"shortResult\":\"3/4 cases passed\",\"score\":0.75}\r\n")
        #expect(crlf.shortResult == "3/4 cases passed")
        #expect(crlf.score == 0.75)
        #expect(crlf.longResult == "stdout:\nchecking...")
        // And byte-identical to the LF reading, which is the contract.
        #expect(crlf == lf)
    }

    @Test func aLoneCRFooterIsFoundToo() {
        let cr = interpret(stdout: "checking...\r{\"shortResult\":\"ok\",\"score\":0.5}\r", exitCode: 1)
        #expect(cr.status == .fail)
        #expect(cr.shortResult == "ok")
        #expect(cr.score == 0.5)
    }

    @Test func aCRLFPlainTextLastLineIsTrimmedOfItsLineBreak() {
        // No footer: the last non-empty line is the summary, and it must not
        // carry the CRLF into the one-line result.
        let result = interpret(stdout: "first\r\nhello\r\n")
        #expect(result.shortResult == "hello")
        #expect(result.longResult == "stdout:\nfirst\r\nhello")
    }

    // MARK: - classifyScriptInterpreter (the #754 extensionless path)

    @Test func aCRLFPythonFileWithALeadingCommentStillLooksLikePython() {
        let source = "# header\r\nimport os\r\n\r\ndef main():\r\n    pass\r\n"
        #expect(classifyScriptInterpreter(name: "run", source: source) == .python)
    }

    @Test func aShebangAfterABOMAndABlankCRLFLineIsRecognised() {
        let source = "\u{feff}\r\n#!/usr/bin/env lua\r\nprint(1)\r\n"
        #expect(classifyScriptInterpreter(name: "run", source: source) == .lua)
    }

    @Test func aCRLFShebangLineDoesNotSwallowTheRestOfTheFile() {
        // With the whole file read as one "line", a later mention of another
        // interpreter could have won. Only the first line decides.
        let source = "#!/bin/sh\r\necho python\r\n"
        #expect(classifyScriptInterpreter(name: "run", source: source) == .sh)
    }
}
