// Tests/CoreTests/JSONFooterGrammarTests.swift
//
// What RunnerCore's footer parser (JSONLite) ACCEPTS and REJECTS, as opposed to
// what it computes — `JSONFooterNumberParsingTests` next door pins the numeric
// values, and between them they cover the parser.
//
// The 2026-08-19 sweep (run 32265903112) reported ten surviving mutants in
// JSONLite and the two it killed were both in number parsing. That is the shape
// of the gap: the footer contract only names `shortResult` and `score`, so the
// parser had been tested on the two field types those use, while remaining a
// general JSON parser that a script may legitimately hand an array, a null, a
// boolean or a `\u` escape. Every mutant below was confirmed SURVIVED by
// `Tools/mutation/verify-survivor.py` against that run's record before the test
// was written, and KILLED after.
//
// `parseJSON` is internal to RunnerCore, so — as in the sibling suite — it is
// exercised through the public `interpretScriptOutput`. The lever is that a last
// stdout line is only treated as a footer when it parses as a JSON *object*: if
// any part of the line fails to parse, the footer is dropped and `shortResult`
// falls back to the raw line. So "shortResult is the footer's value" proves the
// line parsed, and "shortResult is the whole raw line" proves it did not.

import Core
import Testing

@Suite struct JSONFooterGrammarTests {

    private func interpret(stdout: String) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(
                exitCode: 0, stdout: stdout, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    /// Kills the `RelationalOperatorReplacement` on `isAtEnd` (`pos >= count` →
    /// `pos <= count`), which makes "at end" true almost everywhere and so lets
    /// `parseJSON`'s trailing-content guard pass on anything.
    ///
    /// A footer is the whole line or it is not a footer. Accepting a prefix
    /// would let a line that merely BEGINS with an object silently set a
    /// student's score from whatever that prefix said.
    @Test func aLineIsNotAFooterWhenAnythingFollowsTheObject() {
        let line = #"{"shortResult":"ok","score":0.5} and then some prose"#
        let result = interpret(stdout: line)
        #expect(result.shortResult == line)
        #expect(result.score == 1.0)  // no footer, so the exit code decides
    }

    /// Kills `ChangeLogicalConnector` candidate 2 on `skipWhitespace`
    /// (`c == "\t" && c == "\n"`), which stops tabs being skipped.
    ///
    /// `trimHorizontal` strips tabs from the ENDS of the line before the parser
    /// sees it, so only an interior tab reaches `skipWhitespace` — which is
    /// exactly what a script that pretty-prints its footer with tabs emits.
    @Test func interiorTabsBetweenTokensAreSkipped() {
        let result = interpret(stdout: "{\"shortResult\":\t\"ok\",\t\"score\":\t0.25}")
        #expect(result.shortResult == "ok")
        #expect(result.score == 0.25)
    }

    /// Kills `ChangeLogicalConnector` candidate 3 on `skipWhitespace`
    /// (`c == "\n" && c == "\r"`), which stops a carriage return being skipped.
    ///
    /// This is a LONE `\r`, deliberately, and it is the only way that arm is
    /// reachable. A `\r\n` is a single `Character` in Swift, so it never reaches
    /// the parser as a bare `\r` — that grapheme-cluster behaviour is #1457,
    /// where CRLF output loses its footer entirely, and this test must not be
    /// read as covering it. `\n` alone is unreachable here for the same reason
    /// the line was split on it; Muter never mutates that arm in isolation, so
    /// there is nothing separate to close.
    @Test func aTrailingCarriageReturnDoesNotDefeatTheFooter() {
        let result = interpret(stdout: "{\"shortResult\":\"ok\",\"score\":0.5}\r")
        #expect(result.shortResult == "ok")
        #expect(result.score == 0.5)
    }

    /// Kills `ChangeLogicalConnector` candidate 2 at the `parseValue` dispatch
    /// (`c >= "0" || c <= "9"`), which is a tautology — every character then
    /// routes to `parseNumber` instead of being rejected.
    ///
    /// A leading `+` is the case that makes it visible: JSON forbids it, but
    /// `parseDoubleLiteral` accepts one (it has to read exponents like `1e+3`),
    /// so under the mutant `+5` becomes a number and the malformed footer is
    /// honoured.
    @Test func aLeadingPlusIsNotAValidNumberAndVoidsTheFooter() {
        let line = #"{"shortResult":"ok","score":+5}"#
        #expect(interpret(stdout: line).shortResult == line)
    }

    /// Kills the `RelationalOperatorReplacement` on the empty-array check
    /// (`current == "]"` → `!=`), which returns an empty array for a populated
    /// one and mis-parses `[]`.
    @Test func arrayValuesParseWhetherEmptyOrPopulated() {
        #expect(interpret(stdout: #"{"shortResult":"ok","cases":[1,2,3]}"#).shortResult == "ok")
        #expect(interpret(stdout: #"{"shortResult":"ok","cases":[]}"#).shortResult == "ok")
    }

    /// Kills the `RelationalOperatorReplacement` on `parseUnicodeEscape`'s bounds
    /// guard (`pos + 4 <= count` → `>=`), which inverts it: the escape is
    /// rejected whenever there is room for it and attempted when there is not.
    @Test func unicodeEscapesInStringsParse() {
        // `\u0042` is the letter B; the parser must decode it rather than
        // pass it through, so the footer reads "ABC".
        let result = interpret(stdout: #"{"shortResult":"A\u0042C"}"#)
        #expect(result.shortResult == "ABC")
    }

    /// Kills the `SwapTernary` in `parseNull`, which returns nil for `null` and
    /// `.null` for everything else — dropping any footer carrying a JSON null.
    @Test func nullValuesParse() {
        #expect(interpret(stdout: #"{"shortResult":"ok","detail":null}"#).shortResult == "ok")
    }

    /// Kills both `RelationalOperatorReplacement`s in `matchLiteral` — the
    /// bounds guard (`pos + lit.count <= count` → `>=`) and the character
    /// comparison (`!= ch` → `== ch`, which returns false on the first character
    /// that MATCHES). Either one makes every literal fail, so `true`, `false`
    /// and `null` all stop parsing.
    @Test func booleanLiteralsParse() {
        #expect(interpret(stdout: #"{"shortResult":"ok","passed":true}"#).shortResult == "ok")
        #expect(interpret(stdout: #"{"shortResult":"ok","passed":false}"#).shortResult == "ok")
    }
}
