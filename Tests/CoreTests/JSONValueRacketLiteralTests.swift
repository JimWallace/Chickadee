// Tests/CoreTests/JSONValueRacketLiteralTests.swift
//
// The Racket literal renderer, which until this file had no test anywhere in
// the tree — `racketLiteral` appeared under `Sources/` and nowhere under
// `Tests/`. The 2026-08-19 mutation sweep reported all seven of its mutants as
// survivors for exactly that reason, and unreachable code is not a borderline
// call: no test referenced the property, so no test could tell the difference
// when it changed.
//
// Racket is the opposite of C++ here (see the renderer's own doc): dynamically
// typed, so nothing is unrenderable and there is no refusal table to pin. What
// there is to pin is the spelling of each form, and every expectation below is
// Racket reader syntax rather than a convention chosen here.
//
// Each test names the mutation it was written to kill, so a later reader can
// tell which expectations are load-bearing and which are scaffolding.

import Foundation
import Testing

@testable import Core

@Suite struct JSONValueRacketLiteralTests {

    /// Kills the `SwapTernary` at the `.bool` case: `#t` and `#f` are not
    /// interchangeable, and a swapped pair inverts every generated boolean
    /// expectation while still producing a legal Racket program.
    @Test func booleansUseRacketReaderSyntax() {
        #expect(JSONValue.bool(true).racketLiteral == "#t")
        #expect(JSONValue.bool(false).racketLiteral == "#f")
    }

    /// `'null`, not `'()` and not `#f` — the renderer's doc explains why each
    /// of those would collide with a value an expectation could legitimately
    /// want.
    @Test func nullIsTheSymbolRacketsJSONReaderProduces() {
        #expect(JSONValue.null.racketLiteral == "'null")
    }

    @Test func integersRenderBare() {
        #expect(JSONValue.int(0).racketLiteral == "0")
        #expect(JSONValue.int(42).racketLiteral == "42")
        #expect(JSONValue.int(-7).racketLiteral == "-7")
        // Racket integers are arbitrary precision, so the C++/Java suffix
        // question has no analogue: past int32 is still a bare literal.
        #expect(JSONValue.int(2_147_483_648).racketLiteral == "2147483648")
    }

    /// Kills the `SwapTernary` and the FIRST `ChangeLogicalConnector` on the
    /// flonum guard. `2.0` must not read as the exact integer `2`, and it must
    /// not gain a second point either — `equal?` distinguishes `2` from `2.0`,
    /// so both directions are a wrong mark rather than a crash.
    @Test func integralDoublesStayFlonums() {
        #expect(JSONValue.double(2).racketLiteral == "2.0")
        #expect(JSONValue.double(-4).racketLiteral == "-4.0")
        #expect(JSONValue.double(1.5).racketLiteral == "1.5")
    }

    /// Kills the SECOND `ChangeLogicalConnector` on the same guard, which the
    /// integral-double cases above cannot reach: they satisfy the first term
    /// and short-circuit. A double whose Swift description is exponential
    /// carries no `.`, so it exercises the `contains("e")` term alone.
    @Test func exponentialDoublesAreNotGivenASpuriousPoint() {
        #expect(JSONValue.double(1e-5).racketLiteral == "1e-05")
        #expect(JSONValue.double(1e20).racketLiteral == "1e+20")
    }

    @Test func nonFiniteDoublesUseTheReaderSpellings() {
        #expect(JSONValue.double(.nan).racketLiteral == "+nan.0")
        #expect(JSONValue.double(.infinity).racketLiteral == "+inf.0")
        #expect(JSONValue.double(-.infinity).racketLiteral == "-inf.0")
    }

    /// Kills the `SwapTernary` on the array case. An empty list is `(list)`,
    /// and the swapped form renders it `(list )` while rendering every
    /// non-empty array as the empty list — silently dropping every element.
    @Test func arraysRenderAsListApplications() {
        #expect(JSONValue.array([]).racketLiteral == "(list)")
        #expect(JSONValue.array([.int(1)]).racketLiteral == "(list 1)")
        #expect(
            JSONValue.array([.int(1), .string("x"), .bool(false)]).racketLiteral
                == #"(list 1 "x" #f)"#)
        // `(list ...)` rather than a quoted `'(...)` so a nested form is
        // evaluated rather than rendered as literal source text.
        #expect(
            JSONValue.array([.array([.int(1)])]).racketLiteral == "(list (list 1))")
    }

    /// Kills the `RelationalOperatorReplacement` on the key sort. Key order is
    /// not cosmetic: `JSONValue.object` is a Dictionary, so without the sort
    /// the generated source differs run to run and the `spec_hash` header that
    /// makes manifest bytes change when a case changes stops meaning anything.
    @Test func objectKeysAreSortedAscending() {
        #expect(JSONValue.object([:]).racketLiteral == "(hash)")
        #expect(
            JSONValue.object(["b": .int(2), "a": .int(1), "c": .int(3)]).racketLiteral
                == #"(hash "a" 1 "b" 2 "c" 3)"#)
    }

    @Test func stringsTakeRacketsEscapeSet() {
        #expect(JSONValue.string("ok").racketLiteral == #""ok""#)
        #expect(JSONValue.string("a\"b").racketLiteral == #""a\"b""#)
        #expect(JSONValue.string(#"a\b"#).racketLiteral == #""a\\b""#)
        #expect(JSONValue.string("a\nb\tc\rd").racketLiteral == #""a\nb\tc\rd""#)
        // Racket has no `\/`, so a solidus passes through unescaped where the
        // JSON escape set would allow escaping it.
        #expect(JSONValue.string("a/b").racketLiteral == #""a/b""#)
        // Racket source is UTF-8: printable non-ASCII needs no escape.
        #expect(JSONValue.string("é").racketLiteral == #""é""#)
    }

    /// Kills the `ChangeLogicalConnector` in the string encoder's control
    /// character guard. Under `&&` no scalar satisfies both terms, so every
    /// control character is embedded raw — which for a stray NUL makes the
    /// generated file unparseable rather than merely unreadable.
    @Test func controlCharactersAreEscapedIncludingDEL() {
        #expect(JSONValue.string("a\u{01}b").racketLiteral == #""a\u0001b""#)
        #expect(JSONValue.string("a\u{00}b").racketLiteral == #""a\u0000b""#)
        #expect(JSONValue.string("a\u{1F}b").racketLiteral == #""a\u001Fb""#)
        // 0x7F is above the 0x20 floor, so it is the second term's own case.
        #expect(JSONValue.string("a\u{7F}b").racketLiteral == #""a\u007Fb""#)
        // 0x20 itself is printable and must survive as a space.
        #expect(JSONValue.string("a b").racketLiteral == #""a b""#)
    }
}
