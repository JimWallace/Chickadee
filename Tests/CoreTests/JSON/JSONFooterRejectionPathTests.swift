// Tests/CoreTests/JSON/JSONFooterRejectionPathTests.swift
//
// Paths of RunnerCore's footer parser (JSONLite) that the grammar and number
// suites do not reach: an empty object as a value, an unknown escape, an
// unterminated string, and a misspelled `null` or boolean.
//
// `parseJSON` is internal to RunnerCore, so these tests drive it through the
// public `interpretScriptOutput`, as `JSONFooterGrammarTests` does. A last line
// counts as a footer only when the whole line parses as a JSON object. So
// "shortResult is the footer's value" proves the line parsed, and
// "shortResult is the raw line" proves it did not.

import Core
import Testing

@Suite struct JSONFooterRejectionPathTests {

    private func interpret(stdout: String, exitCode: Int32 = 0) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(
                exitCode: exitCode, stdout: stdout, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    @Test func anEmptyObjectIsAValidValueInsideAFooter() {
        let result = interpret(stdout: #"{"details":{},"shortResult":"ok","score":0.5}"#)
        #expect(result.shortResult == "ok")
        #expect(result.score == 0.5)
    }

    @Test func anEmptyObjectIsAValidFooterWithNoFields() {
        let result = interpret(stdout: "{}")
        // The line parses, so it is a footer, not the raw "{}". With no
        // shortResult and no score, exit code 0 gives the synthesized
        // "passed" and full credit.
        #expect(result.shortResult == "passed")
        #expect(result.score == 1.0)
    }

    /// JSON allows eight one-letter escapes and `\u`. Any other letter after
    /// a backslash, or a backslash that escapes the closing brace, is not
    /// JSON, so the line is not a footer.
    @Test(arguments: [#"{"shortResult":"ok\q"}"#, #"{"shortResult":"ok\}"#])
    func anUnknownEscapeIsNotAFooter(_ line: String) {
        let result = interpret(stdout: line, exitCode: 1)
        #expect(result.shortResult == line)
        #expect(result.score == 0.0)
    }

    /// The quote is never closed, so the string runs to the end of the line
    /// and swallows the closing brace.
    @Test func anUnterminatedStringIsNotAFooter() {
        let line = #"{"shortResult":"ok}"#
        let result = interpret(stdout: line)
        #expect(result.shortResult == line)
    }

    @Test func aMisspelledNullIsNotAFooter() {
        let line = #"{"shortResult":"ok","score":0.25,"extra":nul}"#
        let result = interpret(stdout: line)
        #expect(result.shortResult == line)
        #expect(result.score == 1.0)
    }

    @Test(arguments: ["ture", "flase", "t", "fals"])
    func aMisspelledBooleanIsNotAFooter(_ spelling: String) {
        let line = #"{"shortResult":"ok","score":0.25,"extra":\#(spelling)}"#
        let result = interpret(stdout: line)
        #expect(result.shortResult == line)
        #expect(result.score == 1.0)
    }

    @Test func aCorrectlySpelledNullIsAccepted() {
        let result = interpret(stdout: #"{"shortResult":"ok","score":0.25,"extra":null}"#)
        #expect(result.shortResult == "ok")
        #expect(result.score == 0.25)
    }
}
