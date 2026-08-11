// Tests/APITests/GeneratedSourceFixtures.swift
//
// One fixed family per `PatternKind` and one fixed check per
// `NotebookCheckKind`, shared by the two suites that drive every kind:
//
//   * LanguageConformanceMatrixTests — does it render, and does it parse?
//   * GeneratedSourceGoldenTests     — does it render the SAME BYTES as before?
//
// They must be shared, and they must be FIXED. Shared, because a golden that
// snapshots a different family than the matrix renders would let a regression
// hide in the gap. Fixed, because the goldens are byte comparisons: any change
// here rewrites every golden, which is exactly the review signal wanted when
// the fixtures change on purpose and exactly the noise not wanted otherwise.
//
// Semantics do not have to be pedagogically sensible — the assertions are "it
// renders", "it parses", and "it has not changed" — but the SHAPE does, because
// several kinds read `args` and `expected` positionally.

import Core
import Foundation

enum GeneratedSourceFixtures {

    /// A reference implementation of `classify(x)` in each language, for
    /// `.differential` — the one kind whose family carries source.
    ///
    /// This is why `family(kind:)` takes a language at all. Every other kind's
    /// fixture is language-agnostic: `args` and `expected` are JSON, and the
    /// renderer turns them into that language's literals. A reference
    /// implementation cannot be, because it IS source. Six spellings of the
    /// same trivial function, each returning 1 whatever it is given, so the
    /// golden diffs stay about the harness around them.
    ///
    /// Each must define `ck_ref_classify` — the name the renderer calls, and
    /// the one the validator makes an instructor supply.
    static let differentialReference: [AssignmentLanguage: String] = [
        .python: "def ck_ref_classify(x):\n    return 1",
        .r: "ck_ref_classify <- function(x) 1",
        .lua: "function ck_ref_classify(x)\n    return 1\nend",
        .octave: "function r = ck_ref_classify(x)\n  r = 1;\nend",
        .cpp: "int ck_ref_classify(double x) { return 1; }",
        .racket: "(define (ck_ref_classify x) 1)",
        // `ck_ref_Solution_classify`, because Java's target is QUALIFIED and
        // `differentialReferenceName` sanitizes the dot — see that property.
        // A class member, not a free function: Java has none.
        .java: "static int ck_ref_Solution_classify(double x) { return 1; }",
    ]

    /// The family target, in the shape `language` requires.
    ///
    /// Java is the one language whose targets are QUALIFIED (`Class.method`):
    /// it has no free functions, and a public class must live in a file of its
    /// own name, so a generated test has to say the class out loud. A bare name
    /// would render the renderer's undefined-identifier backstop into every
    /// Java golden — technically honest, and useless as a fixture.
    ///
    /// Exhaustive so an eighth language states its answer rather than
    /// inheriting Python's.
    static func fixtureFunctionName(for language: AssignmentLanguage) -> String {
        switch language {
        case .java: return "Solution.classify"
        case .python, .r, .lua, .octave, .cpp, .racket: return "classify"
        }
    }

    /// One plausible family per kind, in `language`.
    ///
    /// The language matters for exactly one kind — see `differentialReference`.
    /// It defaults to Python so the call sites that render a language-agnostic
    /// kind stay unchanged.
    static func family(kind: PatternKind, language: AssignmentLanguage = .python) -> PatternFamily {
        let example: PatternCase
        switch kind {
        case .differential:
            // No `expected`: this kind computes it from the reference, and an
            // authored one would be ignored. `.null` says that out loud.
            example = PatternCase(key: "01", label: "d", args: [.double(18.49)], expected: .null)
        case .variableEquality:
            example = PatternCase(key: "01", label: "v", args: [.string("total")], expected: .int(3))
        case .returnTypeCheck:
            example = PatternCase(key: "01", label: "t", args: [.int(1)], expected: .string("int"))
        case .exceptionExpected:
            example = PatternCase(
                key: "01", label: "e", args: [.int(-1)], expected: .string("ValueError"))
        case .stdoutEquality:
            example = PatternCase(
                key: "01", label: "s", args: [.int(1)], expected: .string("hello"))
        case .unorderedEquality:
            example = PatternCase(
                key: "01", label: "u", args: [.int(1)], expected: .array([.int(1), .int(2)]))
        case .performanceThreshold:
            example = PatternCase(key: "01", label: "p", args: [.int(1)], expected: .double(0.5))
        case .boundaryEquality, .approximateEquality:
            example = PatternCase(key: "01", label: "b", args: [.double(18.49)], expected: .int(1))
        }
        return PatternFamily(
            id: "fam", name: "Family", kind: kind,
            functionName: fixtureFunctionName(for: language), paramNames: ["x"], cases: [example],
            referenceImplementation: kind == .differential
                ? differentialReference[language] : nil)
    }

    /// One plausible check per kind, carrying the fields those kinds read.
    static func check(kind: NotebookCheckKind) -> NotebookCheck {
        NotebookCheck(
            id: "chk", name: "Check", kind: kind,
            variable: "df",
            expectedRows: 3, expectedCols: 2,
            expectedColumns: ["a", "b"],
            expectedCSV: "a,b\n1,2\n")
    }

    /// Notebook-check kinds a language legitimately does not implement. Naming
    /// them is the point: an unsupported kind must be a recorded decision, not
    /// an omission an instructor discovers.
    static let notebookCheckKindExceptions: [AssignmentLanguage: Set<NotebookCheckKind>] = [
        // `astStructure` inspects a Python AST and has no meaning elsewhere.
        .r: [.astStructure],
        // Lua's env is bare `xeus-lua` — emscripten-forge ships no Lua library
        // packages at all — so the exclusions follow from the language rather
        // than from a missing renderer:
        //   * the four data-frame kinds need a data frame, and Lua has no such
        //     type and no package that provides one;
        //   * `figureCount` needs a plotting library that counts figures;
        //   * `astStructure` is Python-only, as it is for R.
        // The four that remain need nothing but the language itself.
        .lua: [
            .dataFrameShape, .dataFrameColumns, .dataFrameEquality, .seriesEquality,
            .figureCount, .astStructure,
        ],
        // Octave keeps two of Lua's exclusions and drops the rest, each
        // answered from the language rather than copied (they land on OPPOSITE
        // answers for figureCount and for regex cellContains):
        //   * the four data-frame kinds: core Octave has no data-frame type
        //     (no `table`; the Forge `dataframe` package is not on
        //     emscripten-forge, so neither runner could load it);
        //   * `astStructure` is Python-only, as everywhere.
        // `figureCount` is NOT excluded — Octave plots natively, verified in
        // both runners (the kernel's plotly toolkit; gnuplot-nox + freefont on
        // the images) — and `cellContains` keeps `regex: true`, because
        // Octave's regexp is PCRE.
        .octave: [
            .dataFrameShape, .dataFrameColumns, .dataFrameEquality, .seriesEquality,
            .astStructure,
        ],
        // C++ excludes ALL TEN, categorically rather than per-kind: notebook
        // checks inspect a submitted notebook, and C++ assignments are
        // upload-only with no notebook workflow — there is nothing for any
        // kind to check. `NotebookCheckValidator` refuses every kind at save
        // time with a message saying exactly that.
        .cpp: Set(NotebookCheckKind.allCases),
        // Java excludes ALL TEN for C++'s reason, not Lua's: the exclusion is
        // categorical (upload-only, so no submitted notebook exists for any
        // kind to inspect) rather than a per-kind statement about what the
        // language can express. `NotebookCheckValidator` refuses every kind at
        // save time with a message saying exactly that.
        //
        // Following C++'s precedent deliberately: Racket refuses all ten at
        // save time yet has no entry here, so it stores ten goldens for checks
        // it will never render in anger. That is a known inconsistency, not a
        // pattern to copy.
        .java: Set(NotebookCheckKind.allCases),
    ]

    /// The check kinds `language` is expected to render, in a stable order.
    static func supportedCheckKinds(for language: AssignmentLanguage) -> [NotebookCheckKind] {
        let exceptions = notebookCheckKindExceptions[language] ?? []
        return NotebookCheckKind.allCases.filter { !exceptions.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Pattern kinds in a stable order, so golden filenames do not depend on
    /// declaration order.
    static var orderedPatternKinds: [PatternKind] {
        PatternKind.allCases.sorted { $0.rawValue < $1.rawValue }
    }
}
