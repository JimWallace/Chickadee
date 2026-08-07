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

    /// One plausible family per kind.
    static func family(kind: PatternKind) -> PatternFamily {
        let example: PatternCase
        switch kind {
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
            functionName: "classify", paramNames: ["x"], cases: [example])
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
