// Tests/CoreTests/JSONValueDoubleFormattingTests.swift
//
// One rule, shared by every literal renderer: a finite double must render as
// something the target language reads back as a FLOAT, never as an integer.
//
// Each renderer implements it the same way —
//
//     let s = String(d)
//     return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
//
// — and the 2026-08-19 sweep (run 32265903112) found the same hole in four of
// them. The first `||` term is covered everywhere, because `2.0` is the obvious
// case and every suite tests it. The SECOND term is covered nowhere: reaching it
// needs a double whose Swift description carries an `e` and no `.`, and a search
// for e-notation across all five existing literal suites returned zero hits.
//
// That is not four independent oversights. The renderers were written by copying
// a working one and their tests were copied with them, hole included — so this
// pins the rule ONCE, in a table, where a fifth renderer is one line and cannot
// inherit the gap by being copied from a neighbour.
//
// Non-finite doubles are deliberately absent: every language spells NaN and
// infinity differently, so they belong in the per-language suites (and are
// already there for R, Lua, Octave, C++, Racket and Java; Python's are pinned in
// `JSONValuePythonLiteralTests`).

import Foundation
import Testing

@testable import Core

@Suite struct JSONValueDoubleFormattingTests {

    /// Every renderer, named. Adding one here is the whole cost of keeping a new
    /// language honest about this rule.
    private static let renderers: [(String, @Sendable (JSONValue) -> String)] = [
        ("python", { $0.pythonLiteral }),
        ("r", { $0.rLiteral }),
        ("lua", { $0.luaLiteral }),
        ("octave", { $0.octaveLiteral }),
        ("cpp", { $0.cppLiteral }),
        ("racket", { $0.racketLiteral }),
        ("java", { $0.javaLiteral }),
    ]

    /// The covered half, kept so the table states the whole rule rather than
    /// only its unloved end.
    @Test func integralDoublesKeepExactlyOneDecimalPoint() {
        for (name, render) in Self.renderers {
            #expect(render(.double(2)) == "2.0", "\(name) rendered an integral double wrong")
            #expect(render(.double(-4)) == "-4.0", "\(name) rendered a negative integral wrong")
            #expect(render(.double(1.5)) == "1.5", "\(name) disturbed a non-integral double")
        }
    }

    /// The uncovered half, and the reason this file exists.
    ///
    /// `String(1e-5)` is `"1e-05"` and `String(1e20)` is `"1e+20"` — both carry
    /// an `e` and neither carries a `.`, so they are the only inputs that reach
    /// the guard's second term. Under the surviving mutant that term becomes
    /// `&&`, the guard answers false, and the renderer appends `.0` to a literal
    /// that already has an exponent: `1e-05.0`, which no target language parses.
    @Test func exponentialDoublesAreNotGivenASpuriousPoint() {
        for (name, render) in Self.renderers {
            #expect(render(.double(1e-5)) == "1e-05", "\(name) mangled a small exponential")
            #expect(render(.double(1e20)) == "1e+20", "\(name) mangled a large exponential")
            #expect(render(.double(-1e-5)) == "-1e-05", "\(name) mangled a negative exponential")
        }
    }

    /// The property underneath both tests, stated directly: whatever a renderer
    /// emits for a finite double, reading it back must give the same value. This
    /// is what makes `1e-05.0` a bug rather than a formatting preference — it is
    /// not a number at all.
    @Test func everyRenderedFiniteDoubleIsStillThatDouble() {
        let values: [Double] = [0, 1, -1, 2, 0.5, 1.5, -4, 1e-5, 1e20, -1e-5, 1234.5678]
        for (name, render) in Self.renderers {
            for v in values {
                let text = render(.double(v))
                // Every renderer here emits a bare numeric literal for a finite
                // double, so Swift's own parser is a fair stand-in for the
                // target language's.
                #expect(Double(text) == v, "\(name) rendered \(v) as \(text), which reads back differently")
            }
        }
    }
}
