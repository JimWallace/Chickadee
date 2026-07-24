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

    @Test func supportedKindsAreTheDataFrameFamily() {
        #expect(notebookCheckKindSupportsR(.dataFrameShape))
        #expect(notebookCheckKindSupportsR(.dataFrameColumns))
        #expect(notebookCheckKindSupportsR(.dataFrameEquality))
        #expect(notebookCheckKindSupportsR(.seriesEquality))
        for kind: NotebookCheckKind in [
            .numericArrayClose, .figureCount, .cellContains, .functionExists,
            .variableExists, .astStructure,
        ] {
            #expect(!notebookCheckKindSupportsR(kind), "\(kind.rawValue) is not R-ready yet")
        }
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
            id: "fig1", kind: .figureCount, tier: .pub, points: 1, minFigures: 1)
        #expect(try run(check: check, submission: "x <- 1\n") == 2)
    }
}
