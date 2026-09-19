// Tests/CoreTests/JSONFooterNumberExactnessTests.swift
//
// Pins that a footer's numbers parse to the correctly rounded `Double`, not to
// a value one unit in the last place away from it.
//
// `JSONFooterNumberParsingTests` proves a number PARSES and lands within
// `1e-12` of the intended value, and every assertion there held while the
// parser was a hand-rolled mantissa-times-power-of-ten fold that returned
// `0.7000000000000001` for `"0.7"`. A tolerance is the right shape for "the
// exponent was applied"; it is the wrong shape for "the value is the value",
// because `points × score` reaches a grade and a `metric` is compared for
// ranking, so the last bit is observable. These assertions use `==`.
//
// The parser is `Double(String)` again, which Swift 6.4 made available to
// Embedded Swift (it is what the browser wasm build links). The exponent
// extremes below are the cases the fold got wrong by more than an ulp: it
// produced `inf` for the largest finite double and `0` for the smallest
// normal one.

import Core
import Testing

@Suite struct JSONFooterNumberExactnessTests {

    private func interpret(footer: String) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(exitCode: 0, stdout: footer, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    /// `score` lives in `0...1`, so the everyday partial-credit spellings are
    /// checked through it — exactly the values an instructor's script writes.
    @Test(arguments: [
        ("0.3", 0.3),
        ("0.7", 0.7),
        ("0.85", 0.85),
        ("8.5e-5", 8.5e-5),
        ("0.12345678901234567890", 0.12345678901234568),
    ])
    func scoreParsesToTheCorrectlyRoundedDouble(literal: String, expected: Double) {
        #expect(interpret(footer: "{\"score\":\(literal)}").score == expected)
    }

    /// `metric` is unclamped, so it carries the magnitudes `score` cannot.
    @Test(arguments: [
        ("4.35", 4.35),
        ("123.456e-7", 123.456e-7),
        ("1e308", 1e308),
        ("1.7976931348623157e308", Double.greatestFiniteMagnitude),
        ("2.2250738585072014e-308", Double.leastNormalMagnitude),
    ])
    func metricParsesToTheCorrectlyRoundedDouble(literal: String, expected: Double) {
        #expect(interpret(footer: "{\"metric\":\(literal)}").metric == expected)
    }
}
