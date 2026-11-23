// Tests/APITests/Assignments/ClonedSolutionSourceTests.swift
//
// A copied assignment gets its solution source in the shared directory
// (#1742). The solution-save path writes `solution.py` only there, never into
// the setup zip, and the clone rebuilt the shared directory from the zip
// alone, so a clone of an assignment whose expressions `import solution`
// failed until the next solution save.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

private let solutionNotebook = #"""
    {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"xpython","language":"python"},"language_info":{"name":"python"}},"cells":[{"cell_type":"code","metadata":{},"source":["def answer():\n","    return 42\n"]}]}
    """#

@Suite struct ClonedSolutionSourceTests {

    /// The solution exists only as a validation submission on the source.
    @Test func aClonedAssignmentGetsItsSolutionSource() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CLONE_SOLN")
            let courseID = try course.requireID()
            let sourceSetup = try await makeTestSetup(on: app, id: "setup_clone_soln", courseID: courseID)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "setup_clone_soln", courseID: courseID, title: "Lab 9")
            let author = try await makeTestUser(on: app, username: "clone_soln_author", role: "admin")
            let solution = try await makeTestSubmission(
                on: app, id: "sub_clone_soln", setupID: "setup_clone_soln",
                userID: try author.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            try solutionNotebook.write(toFile: solution.zipPath, atomically: true, encoding: .utf8)
            source.validationSubmissionID = try solution.requireID()
            try await source.save(on: app.db)

            let cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source, sourceSetup: sourceSetup, newTitle: "Lab 9 (W27)",
                targetCourseID: courseID,
                directories: AuthoringDirectories(
                    setups: app.testSetupsDirectory, submissions: app.submissionsDirectory),
                on: app.db)

            let path = app.testSetupsDirectory + "shared/\(try cloned.setup.requireID())/solution.py"
            let written = try String(contentsOfFile: path, encoding: .utf8)
            #expect(written.contains("def answer"))
        }
    }

    // MARK: - The copied solution file and the declared language

    private static let undeclaredManifest =
        #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
    private static let rManifest =
        #"{"schemaVersion":1,"language":"r","languageDeclared":true,"testSuites":[],"timeLimitSeconds":10}"#

    /// Writes the solution source for a copied solution at `solutionPath` into
    /// the setups directory `root`, and returns that setup's shared directory.
    private static func writeCopiedSolution(
        at solutionPath: String, manifest: String, in root: String
    ) async -> String {
        let setup = APITestSetup(
            id: "setup_copied", manifest: manifest, zipPath: root + "setup.zip", courseID: UUID())
        let solution = APISubmission(
            id: "sub_copied", testSetupID: "setup_copied", zipPath: solutionPath, attemptNumber: 1,
            kind: APISubmission.Kind.validation)
        await SolutionNotebookExtractor.writeSolutionSource(
            fromCopiedSolution: solution, setup: setup, testSetupsDirectory: root)
        return root + "shared/setup_copied/"
    }

    private static func temporaryRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory.path + "/copied-solution-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// A copy of an R assignment gets `solution.R`, not the historical `solution.py`.
    @Test func aCopiedSolutionInADeclaredLanguageWritesThatLanguagesFile() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let solutionPath = root + "solution.ipynb"
        try solutionNotebook.write(toFile: solutionPath, atomically: true, encoding: .utf8)

        let shared = await Self.writeCopiedSolution(at: solutionPath, manifest: Self.rManifest, in: root)

        let written = try String(contentsOfFile: shared + "solution.R", encoding: .utf8)
        #expect(written.contains("def answer"))
        #expect(!FileManager.default.fileExists(atPath: shared + "solution.py"))
    }

    /// A solution submitted as a zip holds the notebook inside it.
    @Test func aCopiedSolutionZipIsReadForItsNotebook() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let solutionPath = root + "solution.zip"
        try await writeZipFixture(at: solutionPath, entries: [("work/solution.ipynb", solutionNotebook)])

        let shared = await Self.writeCopiedSolution(
            at: solutionPath, manifest: Self.undeclaredManifest, in: root)

        let written = try String(contentsOfFile: shared + "solution.py", encoding: .utf8)
        #expect(written.contains("def answer"))
    }
}
