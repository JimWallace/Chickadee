// Tests/APITests/NotebookCheckRendererOctaveTests.swift
//
// Executes each SUPPORTED Octave notebook-check kind for real — pass and fail
// both — plus the refusal behaviour for the five unsupported kinds. Runs on
// the same harness as OctavePatternFamilyExecutionTests.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) struct OctaveNotebookCheckExecutionTests {

    private func check(
        kind: NotebookCheckKind,
        variable: String? = nil,
        expectedType: String? = nil,
        expectedArity: Int? = nil,
        expectedArray: [Double]? = nil,
        minFigures: Int? = nil,
        containsText: String? = nil,
        regex: Bool? = nil,
        mustDifferFrom: String? = nil
    ) -> NotebookCheck {
        NotebookCheck(
            id: "chk", name: nil, kind: kind, tier: .pub, points: 1,
            variable: variable,
            expectedArray: expectedArray,
            minFigures: minFigures,
            containsText: containsText,
            regex: regex,
            mustDifferFrom: mustDifferFrom,
            expectedArity: expectedArity,
            expectedType: expectedType)
    }

    private func run(_ check: NotebookCheck, submission: String) throws -> Int32 {
        let generated = renderNotebookCheck(check, language: .octave)
        return try OctavePatternFamilyExecutionTests.run(
            script: generated.script, submission: submission)
    }

    @Test func variableExistsPassesAndFails() throws {
        guard OctavePatternFamilyExecutionTests.hasOctave else { return }
        let existence = check(kind: .variableExists, variable: "total")
        #expect(try run(existence, submission: "total = 10;\n") == 0)
        #expect(try run(existence, submission: "other = 10;\n") == 1)

        let typed = check(kind: .variableExists, variable: "total", expectedType: "numeric")
        #expect(try run(typed, submission: "total = 10;\n") == 0)
        #expect(try run(typed, submission: "total = \"ten\";\n") == 1)
    }

    @Test func functionExistsHonoursArity() throws {
        guard OctavePatternFamilyExecutionTests.hasOctave else { return }
        let bare = check(kind: .functionExists, variable: "combine")
        #expect(
            try run(bare, submission: "function r = combine(a, b)\n  r = a + b;\nend\n") == 0)
        #expect(try run(bare, submission: "x = 1;\n") == 2)

        let arity = check(kind: .functionExists, variable: "combine", expectedArity: 2)
        #expect(
            try run(arity, submission: "function r = combine(a, b)\n  r = a + b;\nend\n") == 0)
        #expect(
            try run(arity, submission: "function r = combine(a)\n  r = a;\nend\n") == 1)
        // varargin satisfies any expected arity (mirrors Python's *args rule).
        #expect(
            try run(arity, submission: "function r = combine(varargin)\n  r = 0;\nend\n") == 0)
    }

    @Test func numericArrayClosePassesAndFails() throws {
        guard OctavePatternFamilyExecutionTests.hasOctave else { return }
        let close = check(
            kind: .numericArrayClose, variable: "results", expectedArray: [1.0, 2.5, 4.0])
        #expect(try run(close, submission: "results = [1.0, 2.5, 4.0];\n") == 0)
        // Shape-blind: a column is the same values.
        #expect(try run(close, submission: "results = [1.0; 2.5; 4.0];\n") == 0)
        #expect(try run(close, submission: "results = [1.0, 2.5, 9.0];\n") == 1)
        #expect(try run(close, submission: "results = [1.0, 2.5];\n") == 1)
    }

    @Test func cellContainsMatchesLiterallyAndByRegex() throws {
        guard OctavePatternFamilyExecutionTests.hasOctave else { return }
        let literal = check(kind: .cellContains, containsText: "for i = 1:10")
        #expect(try run(literal, submission: "for i = 1:10\n  disp(i);\nend\n") == 0)
        #expect(try run(literal, submission: "disp(1:10);\n") == 1)

        // PCRE — the capability Lua refuses and Octave verifiedly has.
        let pcre = check(kind: .cellContains, containsText: #"for\s+\w+\s*=\s*\d+:\d+"#, regex: true)
        #expect(try run(pcre, submission: "for k = 1:5\n  disp(k);\nend\n") == 0)
        #expect(try run(pcre, submission: "disp(\"no loop here\");\n") == 1)
    }

    @Test func figureCountCountsHeadlessFigures() throws {
        guard OctavePatternFamilyExecutionTests.hasOctave else { return }
        let figures = check(kind: .figureCount, minFigures: 2)
        let plotting = """
            figure("visible", "off");
            plot(1:3);
            figure("visible", "off");
            plot(3:-1:1);
            """
        let result = try run(figures, submission: plotting)
        // On an image without gnuplot-nox + fonts-freefont-otf, figure()
        // errors instead of counting — that absence must surface as a loud
        // failure here, because it is exactly what a student's validation
        // would hit.
        #expect(
            result == 0,
            """
            figureCount did not pass on a plotting submission (exit \(result)). If this is a \
            toolkit error, the image is missing gnuplot-nox / fonts-freefont-otf — the two \
            packages that make headless figure creation work under octave-cli.
            """)
        #expect(try run(figures, submission: "x = 1:3;\n") == 1)
    }

    /// A kind with no Octave renderer must error (exit 2) with a message naming
    /// the kind — never trap, never quietly pass.
    @Test func unsupportedKindsErrorExplicitly() throws {
        guard OctavePatternFamilyExecutionTests.hasOctave else { return }
        let refused = check(kind: .dataFrameShape, variable: "df")
        #expect(try run(refused, submission: "df = 1;\n") == 2)
    }

    /// The save-time gate: an unsupported kind is rejected with a message that
    /// names what IS supported, and regex cellContains is NOT rejected (the
    /// Lua-opposite answer).
    @Test func validationRefusesUnsupportedKindsAndAllowsRegex() {
        let refused = check(kind: .seriesEquality, variable: "s")
        #expect(throws: (any Error).self) {
            try validateNotebookChecks([refused], language: .octave)
        }
        let regexCheck = check(kind: .cellContains, containsText: #"a\d+"#, regex: true)
        #expect(throws: Never.self) {
            try validateNotebookChecks([regexCheck], language: .octave)
        }
    }
}
