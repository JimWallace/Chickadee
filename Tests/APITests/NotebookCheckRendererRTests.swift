// Tests/APITests/NotebookCheckRendererRTests.swift
//
// Coverage for the R notebook-check renderer (the data-frame family). As with
// the R pattern families, two layers: CI-safe byte-shape assertions, and a real
// `Rscript` execution of every supported kind against a passing and a failing
// student notebook — silently skipped where `Rscript` is absent.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct NotebookCheckRendererRShapeTests {

    @Test func rChecksGetRExtensionAndSourceTheRuntime() {
        let check = NotebookCheck(
            id: "shape1", kind: .dataFrameShape, tier: .pub, points: 1,
            variable: "patients", expectedRows: 3, expectedCols: 2)
        let bundle = renderNotebookCheck(check, language: .r)
        #expect(bundle.script.filename == "publiccheck_shape1.R")
        #expect(bundle.script.source.contains("source(\"test_runtime.R\")"))
        #expect(bundle.script.source.contains("chickadee_load_student()"))
        #expect(bundle.script.source.contains("is.data.frame(actual)"))
    }

    /// Python output must be untouched — its bytes feed spec_hash /
    /// TestSetupCache keys.
    @Test func pythonOutputIsUnchangedByDefault() {
        let check = NotebookCheck(
            id: "shape1", kind: .dataFrameShape, tier: .pub, points: 1,
            variable: "patients", expectedRows: 3, expectedCols: 2)
        #expect(renderNotebookCheck(check) == renderNotebookCheck(check, language: .python))
        let py = renderNotebookCheck(check)
        #expect(py.script.filename == "publiccheck_shape1.py")
        #expect(py.script.source.contains("student_main_state()"))
    }

    /// The expected-values CSV is language-neutral data, so both languages
    /// reference the same sidecar filename.
    @Test func sidecarFilenameIsSharedAcrossLanguages() {
        let check = NotebookCheck(
            id: "eq1", kind: .dataFrameEquality, tier: .pub, points: 1,
            variable: "df", expectedCSV: "a,b\n1,2\n")
        let py = notebookCheckAllGeneratedFilenames(check, language: .python)
        let r = notebookCheckAllGeneratedFilenames(check, language: .r)
        #expect(py.contains("_expected_eq1.csv"))
        #expect(r.contains("_expected_eq1.csv"))
        #expect(py.contains("publiccheck_eq1.py"))
        #expect(r.contains("publiccheck_eq1.R"))
    }

    /// Every kind but `astStructure` renders in R — its predicate vocabulary
    /// (`list_comprehension`) has no R analogue and needs a design decision,
    /// not a port.
    @Test func everyKindButASTStructureRendersInR() {
        for kind in NotebookCheckKind.allCases where kind != .astStructure {
            #expect(notebookCheckKindSupportsR(kind), "\(kind.rawValue) should render in R")
        }
        #expect(!notebookCheckKindSupportsR(.astStructure))
    }

    /// Python's bytes must not move for any of the newly-added kinds either —
    /// they feed `spec_hash` and `TestSetupCache` keys.
    @Test(arguments: [
        NotebookCheckKind.variableExists, .functionExists, .numericArrayClose, .figureCount,
    ])
    func pythonBytesUnchangedForTheNewKinds(_ kind: NotebookCheckKind) {
        let check = NotebookCheck(
            id: "k1", kind: kind, tier: .pub, points: 1, variable: "x",
            expectedArray: [1.0, 2.0], minFigures: 2, expectedArity: 1, expectedType: "numeric")
        #expect(renderNotebookCheck(check) == renderNotebookCheck(check, language: .python))
        #expect(renderNotebookCheck(check).script.filename == "publiccheck_k1.py")
        #expect(renderNotebookCheck(check, language: .r).script.filename == "publiccheck_k1.R")
    }

    /// `cellContains` reads the submission's *source*, so it must not evaluate
    /// it — a student whose top-level code errors should still be told whether
    /// they wrote the cell.
    @Test func cellContainsDoesNotEvaluateTheSubmission() {
        let check = NotebookCheck(
            id: "cc", kind: .cellContains, tier: .pub, points: 1, containsText: "groupby")
        let source = renderNotebookCheck(check, language: .r).script.source
        #expect(source.contains("chickadee_student_cells()"))
        #expect(!source.contains("chickadee_load_student()"))
    }

    /// The figure counter has to be armed before the submission is evaluated,
    /// so it deliberately does not use the shared preamble.
    @Test func figureCountArmsItsHooksBeforeLoadingTheStudent() throws {
        let check = NotebookCheck(id: "figs", kind: .figureCount, tier: .pub, points: 1, minFigures: 2)
        let source = renderNotebookCheck(check, language: .r).script.source
        let hookIndex = try #require(source.range(of: "setHook(\"plot.new\""))
        let loadIndex = try #require(source.range(of: "chickadee_load_student()"))
        #expect(hookIndex.lowerBound < loadIndex.lowerBound)
    }

    /// An unsupported kind must be refused at save time, naming what *is*
    /// supported — not silently rendered as Python for an R assignment.
    @Test func unsupportedKindIsRejectedForRAtSaveTime() {
        let check = NotebookCheck(
            id: "ast1", kind: .astStructure, tier: .pub, points: 1,
            requiredConstructs: ["for_loop"])
        // Fine for Python…
        #expect(throws: Never.self) {
            try validateNotebookChecks([check], language: .python)
        }
        // …refused for R.
        #expect(throws: (any Error).self) {
            try validateNotebookChecks([check], language: .r)
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(3))) struct NotebookCheckRendererRExecutionTests {

    private static var hasRscript: Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["Rscript", "--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func canonicalRuntime() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Tools/runner-support/test_runtime.R"),
            encoding: .utf8)
    }

    /// Writes the runtime, the student submission, the rendered check and any
    /// sidecars into a temp dir and runs the check. Returns the exit code
    /// (0 pass / 1 fail / 2 error).
    private func run(check: NotebookCheck, submission: String) throws -> Int32 {
        let bundle = renderNotebookCheck(check, language: .r)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-rcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try Self.canonicalRuntime().write(
            to: dir.appendingPathComponent("test_runtime.R"), atomically: true, encoding: .utf8)
        try submission.write(
            to: dir.appendingPathComponent("solution.R"), atomically: true, encoding: .utf8)
        for (name, contents) in bundle.sidecars {
            try contents.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let scriptURL = dir.appendingPathComponent(bundle.script.filename)
        try bundle.script.source.write(to: scriptURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["Rscript", scriptURL.path]
        proc.currentDirectoryURL = dir
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private let patientsFrame = """
        patients <- data.frame(
            id = c(1, 2, 3),
            bmi = c(22.5, 27.1, 31.4),
            stringsAsFactors = FALSE
        )
        """

    @Test func dataFrameShapeChecksRowsAndColumns() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "shape1", kind: .dataFrameShape, tier: .pub, points: 1,
            variable: "patients", expectedRows: 3, expectedCols: 2)
        #expect(try run(check: check, submission: patientsFrame) == 0)
        // Wrong row count.
        #expect(
            try run(
                check: check,
                submission: "patients <- data.frame(id = c(1, 2), bmi = c(1.0, 2.0))\n") == 1)
        // Not a data frame at all.
        #expect(try run(check: check, submission: "patients <- c(1, 2, 3)\n") == 1)
        // Never defined.
        #expect(try run(check: check, submission: "something_else <- 1\n") == 1)
    }

    /// A tibble-like object inheriting from data.frame must still satisfy the
    /// frame checks — the reason `is.data.frame` is the guard rather than an
    /// exact class comparison.
    @Test func dataFrameShapeAcceptsAnInheritingClass() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "shape1", kind: .dataFrameShape, tier: .pub, points: 1,
            variable: "patients", expectedRows: 3, expectedCols: 2)
        let tibbleish = patientsFrame + "\nclass(patients) <- c(\"tbl_df\", \"tbl\", \"data.frame\")\n"
        #expect(try run(check: check, submission: tibbleish) == 0)
    }

    @Test func dataFrameColumnsExactAndSuperset() throws {
        guard Self.hasRscript else { return }
        let exact = NotebookCheck(
            id: "cols1", kind: .dataFrameColumns, tier: .pub, points: 1,
            variable: "patients", expectedColumns: ["id", "bmi"], columnMatch: .exact)
        #expect(try run(check: exact, submission: patientsFrame) == 0)
        // Order matters under .exact.
        #expect(
            try run(
                check: exact,
                submission: "patients <- data.frame(bmi = c(1.0), id = c(1))\n") == 1)

        let superset = NotebookCheck(
            id: "cols2", kind: .dataFrameColumns, tier: .pub, points: 1,
            variable: "patients", expectedColumns: ["id"], columnMatch: .superset)
        // Extra columns are fine under .superset.
        #expect(try run(check: superset, submission: patientsFrame) == 0)
        #expect(
            try run(check: superset, submission: "patients <- data.frame(bmi = c(1.0))\n") == 1)
    }

    @Test func dataFrameEqualityComparesValuesWithinTolerance() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "eq1", kind: .dataFrameEquality, tier: .pub, points: 1,
            variable: "patients", expectedCSV: "id,bmi\n1,22.5\n2,27.1\n3,31.4\n",
            rtol: 1e-5, atol: 1e-8)
        #expect(try run(check: check, submission: patientsFrame) == 0)

        // Within tolerance.
        let jittered = """
            patients <- data.frame(id = c(1, 2, 3), bmi = c(22.500000001, 27.1, 31.4))
            """
        #expect(try run(check: check, submission: jittered) == 0)

        // Outside tolerance.
        let wrong = """
            patients <- data.frame(id = c(1, 2, 3), bmi = c(22.5, 27.1, 99.9))
            """
        #expect(try run(check: check, submission: wrong) == 1)

        // Wrong column names.
        let renamed = """
            patients <- data.frame(id = c(1, 2, 3), BMI = c(22.5, 27.1, 31.4))
            """
        #expect(try run(check: check, submission: renamed) == 1)
    }

    /// A character column compares as text, so a factor holding the same labels
    /// still passes — students frequently end up with one or the other.
    @Test func dataFrameEqualityComparesTextColumnsAsText() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "eq2", kind: .dataFrameEquality, tier: .pub, points: 1,
            variable: "df", expectedCSV: "name,n\nada,1\ngrace,2\n")
        let asCharacter = """
            df <- data.frame(name = c("ada", "grace"), n = c(1, 2), stringsAsFactors = FALSE)
            """
        let asFactor = """
            df <- data.frame(name = factor(c("ada", "grace")), n = c(1, 2))
            """
        #expect(try run(check: check, submission: asCharacter) == 0)
        #expect(try run(check: check, submission: asFactor) == 0)
        #expect(
            try run(
                check: check,
                submission: "df <- data.frame(name = c(\"ada\", \"hopper\"), n = c(1, 2))\n") == 1)
    }

    @Test func seriesEqualityAcceptsVectorAndOneColumnFrame() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "ser1", kind: .seriesEquality, tier: .pub, points: 1,
            variable: "bmis", expectedCSV: "bmi\n22.5\n27.1\n31.4\n", rtol: 1e-5, atol: 1e-8)
        #expect(try run(check: check, submission: "bmis <- c(22.5, 27.1, 31.4)\n") == 0)
        // A one-column frame is unwrapped rather than rejected.
        #expect(
            try run(check: check, submission: "bmis <- data.frame(bmi = c(22.5, 27.1, 31.4))\n") == 0)
        // Wrong length.
        #expect(try run(check: check, submission: "bmis <- c(22.5, 27.1)\n") == 1)
        // Wrong value.
        #expect(try run(check: check, submission: "bmis <- c(22.5, 27.1, 0)\n") == 1)
        // A multi-column frame is ambiguous and refused.
        #expect(
            try run(
                check: check,
                submission: "bmis <- data.frame(a = c(1, 2, 3), b = c(1, 2, 3))\n") == 1)
    }

    /// A kind with no R renderer fails closed with a clear message rather than
    /// silently passing, if one ever reaches grading past validation.
    @Test func unsupportedKindFailsClosedAtGradingTime() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "ast1", kind: .astStructure, tier: .pub, points: 1,
            requiredConstructs: ["for_loop"])
        #expect(try run(check: check, submission: "x <- 1\n") == 2)
    }

    // MARK: - .variableExists

    @Test func variableExistsChecksPresenceAndType() throws {
        guard Self.hasRscript else { return }
        let untyped = NotebookCheck(
            id: "v1", kind: .variableExists, tier: .pub, points: 1, variable: "beats")
        #expect(try run(check: untyped, submission: "beats <- 5\n") == 0)
        #expect(try run(check: untyped, submission: "other <- 5\n") == 1)

        // "DataFrame" is the Python spelling; it must mean `data.frame` in R so
        // a check authored for a Python assignment survives the conversion.
        let typed = NotebookCheck(
            id: "v2", kind: .variableExists, tier: .pub, points: 1,
            variable: "df", expectedType: "DataFrame")
        #expect(try run(check: typed, submission: "df <- data.frame(a = 1:3)\n") == 0)
        #expect(try run(check: typed, submission: "df <- c(1, 2, 3)\n") == 1)
    }

    /// A variable built by top-level calls is the case Python needs
    /// `student_main_state()` for; in R it is simply in the environment.
    @Test func variableExistsSeesAValueBuiltByTopLevelCalls() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "v3", kind: .variableExists, tier: .pub, points: 1,
            variable: "total", expectedType: "numeric")
        let submission = """
            add <- function(a, b) a + b
            total <- add(2, 3)
            """
        #expect(try run(check: check, submission: submission) == 0)
    }

    // MARK: - .functionExists

    @Test func functionExistsChecksDefinitionAndCallability() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "f1", kind: .functionExists, tier: .pub, points: 1, variable: "bmi")
        #expect(try run(check: check, submission: "bmi <- function(m, h) m / h^2\n") == 0)
        #expect(try run(check: check, submission: "x <- 1\n") == 1)
        // Defined, but shadowed by a non-function.
        #expect(try run(check: check, submission: "bmi <- 27.1\n") == 1)
    }

    @Test func functionExistsChecksArity() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "f2", kind: .functionExists, tier: .pub, points: 1,
            variable: "bmi", expectedArity: 2)
        #expect(try run(check: check, submission: "bmi <- function(m, h) m / h^2\n") == 0)
        #expect(try run(check: check, submission: "bmi <- function(m) m\n") == 1)
        // A defaulted third argument is optional, so 2 is still satisfiable.
        #expect(try run(check: check, submission: "bmi <- function(m, h, r = 1) m / h^2\n") == 0)
        // `...` means "accepts more", so one required argument still passes.
        #expect(try run(check: check, submission: "bmi <- function(m, ...) m\n") == 0)
        // …but three *required* arguments cannot be called with two.
        #expect(try run(check: check, submission: "bmi <- function(a, b, c) a\n") == 1)
    }

    // MARK: - .numericArrayClose

    @Test func numericArrayCloseComparesWithinTolerance() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "n1", kind: .numericArrayClose, tier: .pub, points: 1,
            variable: "scores", rtol: 1e-5, atol: 1e-8, expectedArray: [1.0, 2.5, 3.25])
        #expect(try run(check: check, submission: "scores <- c(1, 2.5, 3.25)\n") == 0)
        // Inside the tolerance.
        #expect(try run(check: check, submission: "scores <- c(1, 2.500001, 3.25)\n") == 0)
        // Outside it.
        #expect(try run(check: check, submission: "scores <- c(1, 2.6, 3.25)\n") == 1)
        // Wrong length.
        #expect(try run(check: check, submission: "scores <- c(1, 2.5)\n") == 1)
        // Missing entirely.
        #expect(try run(check: check, submission: "other <- c(1, 2.5, 3.25)\n") == 1)
        // Not numeric at all.
        #expect(try run(check: check, submission: "scores <- c(\"a\", \"b\", \"c\")\n") == 1)
    }

    /// Mirrors numpy's `equal_nan` default so a check converted from Python
    /// keeps agreeing with itself.
    @Test func numericArrayCloseTreatsMatchingNaNAndInfAsEqual() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "n2", kind: .numericArrayClose, tier: .pub, points: 1,
            variable: "xs", expectedArray: [Double.nan, .infinity, -.infinity, 1.0])
        #expect(try run(check: check, submission: "xs <- c(NaN, Inf, -Inf, 1)\n") == 0)
        // Sign of the infinity matters.
        #expect(try run(check: check, submission: "xs <- c(NaN, Inf, Inf, 1)\n") == 1)
    }

    // MARK: - .cellContains

    /// The submission the extractor produces: an inert marker comment ahead of
    /// each code cell, which is what gives this check cell granularity.
    private func extractedNotebook(cells: [String]) -> String {
        var out = "# Generated from analysis.ipynb\n\n"
        for (index, body) in cells.enumerated() {
            out += "# ---- chickadee:cell \(index + 1) ----\n"
            out += body + "\n\n"
        }
        return out
    }

    @Test func cellContainsMatchesLiteralText() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "cc1", kind: .cellContains, tier: .pub, points: 1, containsText: "aggregate")
        let hit = extractedNotebook(cells: [
            "df <- read.csv(\"cases.csv\")",
            "aggregate(age ~ sex, data = df, FUN = mean)",
        ])
        #expect(try run(check: check, submission: hit) == 0)
        let miss = extractedNotebook(cells: ["df <- read.csv(\"cases.csv\")", "summary(df)"])
        #expect(try run(check: check, submission: miss) == 1)
    }

    @Test func cellContainsMatchesARegularExpression() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "cc2", kind: .cellContains, tier: .pub, points: 1,
            containsText: "\\$(weight|height|bmi)[[:space:]]*\\|>", regex: true)
        let hit = extractedNotebook(cells: ["df$weight |> hist()"])
        #expect(try run(check: check, submission: hit) == 0)
        // Same shape, but on a variable the check does not accept.
        let miss = extractedNotebook(cells: ["df$age |> hist()"])
        #expect(try run(check: check, submission: miss) == 1)
    }

    /// The "write your own analysis, do not paste the example" constraint.
    @Test func cellContainsRejectsACopyOfTheExample() throws {
        guard Self.hasRscript else { return }
        let example = "aggregate(age ~ sex, data = df, FUN = mean)"
        let check = NotebookCheck(
            id: "cc3", kind: .cellContains, tier: .pub, points: 1,
            containsText: "aggregate", mustDifferFrom: example)
        // Only the example — refused, even re-indented and re-spaced.
        #expect(try run(check: check, submission: extractedNotebook(cells: [example])) == 1)
        #expect(
            try run(
                check: check,
                submission: extractedNotebook(cells: ["   aggregate(age ~ sex,  data = df,  FUN = mean)  "]))
                == 1)
        // Their own version alongside it — accepted.
        #expect(
            try run(
                check: check,
                submission: extractedNotebook(cells: [
                    example, "aggregate(weight ~ department, data = df, FUN = mean)",
                ])) == 0)
    }

    /// A hand-written `.R` upload never went through the extractor, so it has
    /// no markers. The whole file is one cell rather than an error.
    @Test func cellContainsFallsBackToFileGranularityWithoutMarkers() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "cc4", kind: .cellContains, tier: .pub, points: 1, containsText: "aggregate")
        #expect(try run(check: check, submission: "aggregate(age ~ sex, data = df, FUN = mean)\n") == 0)
        #expect(try run(check: check, submission: "summary(df)\n") == 1)
    }

    // MARK: - .figureCount

    @Test func figureCountCountsHighLevelPlots() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "fig2", kind: .figureCount, tier: .pub, points: 1, minFigures: 2)
        let twoCharts = """
            hist(c(1, 2, 2, 3, 3, 3))
            barplot(c(1, 2, 3))
            """
        #expect(try run(check: check, submission: twoCharts) == 0)
        #expect(try run(check: check, submission: "hist(c(1, 2, 3))\n") == 1)
        #expect(try run(check: check, submission: "x <- 1\n") == 1)
    }

    /// The distinction that makes `plot.new` the right hook: adding a line to
    /// an existing chart is not a second chart.
    @Test func figureCountIgnoresLowLevelAdditions() throws {
        guard Self.hasRscript else { return }
        let check = NotebookCheck(
            id: "fig3", kind: .figureCount, tier: .pub, points: 1, minFigures: 2)
        let onePlotPlusDecoration = """
            plot(1:10, 1:10)
            lines(1:10, 10:1)
            points(1:10, rep(5, 10))
            abline(h = 5)
            """
        #expect(try run(check: check, submission: onePlotPlusDecoration) == 1)
    }
}
