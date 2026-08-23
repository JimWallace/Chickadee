// Tests/CoreTests/JSONValuePythonLiteralTests.swift
//
// `pythonLiteral` is the oldest of the seven renderers and the only one with no
// CoreTests file: its assertions live in `Tests/APITests/PatternFamilyRendererTests`,
// which the mutation sweep skips. That is why the 2026-08-19 sweep reported its
// object-key sort as a survivor while the identical sort in the Racket and Java
// renderers had already been pinned — the Python one is exercised, just not by
// anything the sweep runs, and "exercised" is not "asserted on" either way.
//
// The `.0`-suffix rule this renderer shares with its six siblings is pinned once
// in `JSONValueDoubleFormattingTests`; what is here is Python-specific.

import Foundation
import Testing

@testable import Core

@Suite struct JSONValuePythonLiteralTests {

    @Test func scalarsUsePythonSpellings() {
        #expect(JSONValue.null.pythonLiteral == "None")
        #expect(JSONValue.bool(true).pythonLiteral == "True")
        #expect(JSONValue.bool(false).pythonLiteral == "False")
        #expect(JSONValue.int(0).pythonLiteral == "0")
        #expect(JSONValue.int(-7).pythonLiteral == "-7")
        // Python integers are arbitrary precision, so nothing widens or suffixes.
        #expect(JSONValue.int(2_147_483_648).pythonLiteral == "2147483648")
    }

    /// Kills the `RelationalOperatorReplacement` on the key sort
    /// (`$0.key < $1.key` → `>`).
    ///
    /// `JSONValue.object` is a Dictionary, so without the sort the rendered
    /// source differs run to run. That is not cosmetic: generated filenames
    /// embed a `spec_hash` of the rendered bytes, so an unstable order makes a
    /// family look edited on every save.
    ///
    /// This mutant is also why the sweep is worth running on code that already
    /// has tests. The same sort in `racketLiteral` and `javaLiteral` was pinned
    /// in #1463; this one survived because its only assertions are in a suite
    /// the sweep does not run.
    @Test func objectKeysAreSortedAscending() {
        #expect(JSONValue.object([:]).pythonLiteral == "{}")
        #expect(
            JSONValue.object(["b": .int(2), "a": .int(1), "c": .int(3)]).pythonLiteral
                == #"{"a": 1, "b": 2, "c": 3}"#)
        // Sorting is by key, not by insertion or by value.
        #expect(
            JSONValue.object(["z": .int(1), "y": .int(2)]).pythonLiteral
                == #"{"y": 2, "z": 1}"#)
    }

    @Test func arraysAndNestingRenderAsPythonLiterals() {
        #expect(JSONValue.array([]).pythonLiteral == "[]")
        #expect(JSONValue.array([.int(1), .int(2)]).pythonLiteral == "[1, 2]")
        #expect(
            JSONValue.array([.null, .bool(true), .string("x")]).pythonLiteral
                == #"[None, True, "x"]"#)
        #expect(
            JSONValue.object(["a": .array([.int(1)])]).pythonLiteral == #"{"a": [1]}"#)
    }

    @Test func stringsAreEscaped() {
        #expect(JSONValue.string("ok").pythonLiteral == #""ok""#)
        #expect(JSONValue.string("a\"b").pythonLiteral == #""a\"b""#)
        #expect(JSONValue.string(#"a\b"#).pythonLiteral == #""a\\b""#)
        #expect(JSONValue.string("line\nbreak").pythonLiteral == #""line\nbreak""#)
    }
}
