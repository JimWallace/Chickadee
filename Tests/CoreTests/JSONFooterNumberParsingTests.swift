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
//
// It proves ONLY that. A footer whose number parsed to the wrong value is still a
// footer, so every assertion below on `shortResult` alone holds just as well when
// the arithmetic is wrong — which is how mutation testing found that flipping the
// exponent's sign (`exponentSign = -1` → `1`) failed nothing here. The
// value-asserting tests at the bottom are the half that was missing: they read
// the parsed number back through `score`, where a wrong value cannot hide.

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

    // MARK: - The parsed VALUE, not just "it parsed"
    //
    // `score` is the only route by which a footer's number reaches an
    // observable output, and it is clamped to 0...1 — so these cases stay
    // inside that range on purpose, except where the clamp itself is the point.

    @Test(arguments: [
        ("5e-1", 0.5),
        ("2.5E-2", 0.025),
        ("25e-2", 0.25),
        ("1e-3", 0.001),
        ("7.5e-1", 0.75),
        ("1e0", 1.0),
        ("0e5", 0.0),  // a zero mantissa with a positive exponent is still zero
    ])
    func exponentIsAppliedWithTheRightSignAndMagnitude(literal: String, expected: Double) {
        let result = interpret(stdout: "{\"shortResult\":\"x\",\"score\":\(literal)}")
        #expect(result.shortResult == "x")  // the footer was recognised…
        #expect(abs(result.score - expected) < 1e-12)  // …and carries the right number
    }

    @Test func positiveExponentOvershootsAndIsClampedRatherThanNegated() {
        // `1.0e+4` is 10000, clamped to 1. Under a flipped exponent sign it
        // would be 0.0001 — in range, so the clamp cannot mask the difference.
        #expect(interpret(stdout: "{\"score\":1.0e+4}").score == 1)
        // …and the explicit `+` must be consumed rather than ending the number:
        // if it were not, the literal would fail to parse and this would not be
        // a footer at all.
        #expect(interpret(stdout: "{\"shortResult\":\"y\",\"score\":1.0e+4}").shortResult == "y")
    }

    @Test func fractionalDigitsAndExponentCompose() {
        // fractionDigits and exponent are folded into one power of ten, so a
        // literal exercising both at once pins that arithmetic rather than
        // either half alone.
        #expect(abs(interpret(stdout: "{\"score\":1234.5e-4}").score - 0.12345) < 1e-12)
        #expect(abs(interpret(stdout: "{\"score\":0.00075e3}").score - 0.75) < 1e-12)
    }

    @Test func whitespaceAroundAFooterIsToleratedWithTheValueIntact() {
        // Instructors hand-write these footers, so a generously spaced one is a
        // plausible input; the parser skips whitespace at each structural point.
        #expect(interpret(stdout: "{ \"shortResult\" : \"spaced\" , \"score\" : 0.25 }").score == 0.25)
        #expect(
            interpret(stdout: "{ \"shortResult\" : \"spaced\" , \"score\" : 0.25 }").shortResult
                == "spaced")
    }
}
