// Tests/CoreTests/InputsFileRenderingTests.swift
//
// `renderInputsFile` writes the per-student `_ck_inputs.*` preamble every
// generated test loads. Its assertions live in `Tests/APITests`, which the
// mutation sweep does not run, and the Racket form had none at all — which is
// how the 2026-08-19 sweep (run 32265903112) found a `SwapTernary` on Racket's
// empty-versus-populated split surviving.
//
// That mutant is worth naming, because it is not a subtle one: it exchanges the
// two branches AND leaves the entries concatenated onto the wrong side, so an
// assignment with no personalization inputs emits `(define ck-inputs\n  (hash\n`
// — an unterminated form. The file is `dynamic-require`d by every generated
// test, so the failure is a read error on every test in the assignment, for
// every student, with nothing in the test scripts to point at.
//
// The empty case is the one that goes unwritten, in every language, because an
// author testing by hand always has an input. So the shape is pinned twice:
// exact bytes for Racket, and an `allCases` property that a seventh language
// inherits without editing this file.

import Foundation
import Testing

@testable import Core

@Suite struct InputsFileRenderingTests {

    // MARK: - Racket, by byte

    @Test func racketWithNoInputsRendersAClosedEmptyHash() {
        #expect(
            AssignmentLanguage.racket.renderInputsFile([:]) == """
                #lang racket/base
                ; Auto-generated per-student grading inputs (issue #461). Do not edit.
                (provide ck-inputs)
                (define ck-inputs (hash))

                """)
    }

    @Test func racketWithInputsRendersAPopulatedHashInKeyOrder() {
        #expect(
            AssignmentLanguage.racket.renderInputsFile([
                "threshold": "42",
                "alpha": "0.5",
            ]) == """
                #lang racket/base
                ; Auto-generated per-student grading inputs (issue #461). Do not edit.
                (provide ck-inputs)
                (define ck-inputs
                  (hash
                   "alpha" 0.5
                   "threshold" 42))

                """)
    }

    // MARK: - Every language

    /// The empty map is the case a language forgets, so ask it of all of them.
    ///
    /// Balanced delimiters is the weakest useful statement of "this file
    /// parses" that holds across seven syntaxes, and it is exactly what the
    /// Racket survivor breaks.
    @Test(arguments: AssignmentLanguage.allCases)
    func anEmptyInputMapRendersACompleteFile(language: AssignmentLanguage) {
        let rendered = language.renderInputsFile([:])
        #expect(!rendered.isEmpty)
        #expect(rendered.hasSuffix("\n"), "\(language) left the file without a final newline")
        #expect(
            rendered.contains(language.lineCommentPrefix),
            "\(language) dropped the do-not-edit header")
        for (open, close) in [("(", ")"), ("{", "}"), ("[", "]")] {
            #expect(
                rendered.filter { String($0) == open }.count
                    == rendered.filter { String($0) == close }.count,
                "\(language) rendered unbalanced \(open)\(close) for an empty input map")
        }
    }

    /// And the populated case, so the empty-case assertion above cannot be
    /// satisfied by a renderer that always emits the empty form.
    @Test(arguments: AssignmentLanguage.allCases)
    func apopulatedInputMapMentionsEveryKey(language: AssignmentLanguage) {
        let rendered = language.renderInputsFile([
            "threshold": language.literal(.int(42)),
            "label": language.literal(.string("ok")),
        ])
        #expect(rendered.contains("threshold"), "\(language) dropped an input name")
        #expect(rendered.contains("label"), "\(language) dropped an input name")
        #expect(rendered != language.renderInputsFile([:]))
        for (open, close) in [("(", ")"), ("{", "}"), ("[", "]")] {
            #expect(
                rendered.filter { String($0) == open }.count
                    == rendered.filter { String($0) == close }.count,
                "\(language) rendered unbalanced \(open)\(close) for a populated input map")
        }
    }
}
