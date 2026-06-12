// Tests/CoreTests/JSONFooterNumberParsingTests.swift
//
// Pins RunnerCore's embedded-safe JSON number parser (JSONLite.parseDoubleLiteral,
// which replaced `Double(String)` so the parser links under Embedded Swift wasm
// — `Double(String)` lowers to `_swift_stdlib_strtod_clocale`, absent there).
//
// `parseJSON` / `parseDoubleLiteral` are internal to RunnerCore, so we exercise
// them through the public `interpretScriptOutput`: a script's last stdout line is
// only treated as a result footer when it parses as a JSON *object*. If a numeric
// field (e.g. the reserved `score`) failed to parse, the whole object would fail
// to parse, the footer would be ignored, and `shortResult` would fall back to the
// raw line. So "shortResult == the footer's value" proves the number parsed.

import Core
import Testing

@Suite struct JSONFooterNumberParsingTests {

    private func interpret(stdout: String) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(exitCode: 0, stdout: stdout, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    @Test(arguments: [
        "0.75",  // simple decimal (the canonical score)
        "0",  // integer zero
        "-0",  // negative zero
        "200",  // plain integer
        "-1.5",  // negative decimal
        "123456789.0",  // large
        "1e3",  // exponent
        "2.5E-2",  // signed fractional exponent, capital E
        "1.0e+4",  // explicit positive exponent
        "0.000001",  // small magnitude
    ])
    func numericScoreFieldParsesSoFooterIsRecognized(score: String) {
        let result = interpret(stdout: "work\n{\"shortResult\":\"3/4 cases passed\",\"score\":\(score)}")
        #expect(result.shortResult == "3/4 cases passed")
    }

    @Test func malformedNumberFooterFallsBackToRawLine() {
        // "1.2.3" is not a valid number → the object fails to parse → not a footer.
        let line = "{\"shortResult\":\"ok\",\"score\":1.2.3}"
        let result = interpret(stdout: line)
        #expect(result.shortResult == line)
    }

    @Test func bareNumberLineIsValidJSONButNotAFooterObject() {
        // A bare number parses as JSON but isn't an object, so it's not a footer.
        let result = interpret(stdout: "42")
        #expect(result.shortResult == "42")
    }
}
