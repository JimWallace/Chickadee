// Tests/APITests/SavedSolutionPrecedenceTests.swift
//
// A saved solution wins over a `solution.*` bundled in the setup zip.
//
// Every solution save (the editor, MCP `update_solution`, the edit form)
// stores a validation submission and leaves the zip alone. With the zip
// searched first, a bundled entry hid every later save from the editor,
// `get_solution` and the reveal, while validation graded the saved one; and
// an edit-form save with no solution upload re-validated against, and linked,
// the zip's original answer key, reverting the saved one.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct SavedSolutionPrecedenceTests {

    static let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    private static func notebook(_ marker: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["answer = \\"\(marker)\\""],"metadata":{},"outputs":[],"execution_count":null}]}
        """
    }

    /// An assignment whose setup zip bundles a solution, as an instructor's
    /// uploaded zip can.
    private func assignmentWithBundledSolution(
        id: String, on app: Application
    ) async throws -> (APIAssignment, APITestSetup) {
        let setup = try await wrInsertSetup(id: id, manifest: Self.manifest, on: app)
        try await writeZipFixture(
            at: setup.zipPath,
            entries: [("test.sh", "exit 0\n"), ("solution.ipynb", Self.notebook("bundled"))])
        let assignment = try await wrInsertAssignment(testSetupID: id, title: "Lab", isOpen: false, on: app)
        return (assignment, setup)
    }

    /// Stores `marker` as a validation submission and links it, as a save does.
    private func saveSolution(
        _ marker: String, for assignment: APIAssignment, on app: Application
    ) async throws {
        let submissionID = "sub_\(assignment.testSetupID)_\(marker)"
        let path = app.submissionsDirectory + "\(submissionID).ipynb"
        try Data(Self.notebook(marker).utf8).write(to: URL(fileURLWithPath: path))
        try await APISubmission(
            id: submissionID, testSetupID: assignment.testSetupID, zipPath: path, attemptNumber: 1,
            filename: "solution.ipynb", userID: nil, kind: APISubmission.Kind.validation
        ).save(on: app.db)
        assignment.validationSubmissionID = submissionID
        try await assignment.save(on: app.db)
    }

    @Test func aSavedSolutionWinsOverOneBundledInTheZip() async throws {
        try await withWebRoutesApp { app in
            let (assignment, setup) = try await assignmentWithBundledSolution(id: "sol_prec_saved", on: app)
            try await saveSolution("saved", for: assignment, on: app)

            let found = try #require(
                try await resolveSolution(
                    at: SolutionLocation(assignment), setup: setup, sources: SolutionSource.any,
                    db: app.db, testSetupsDirectory: app.testSetupsDirectory))
            #expect(found.source == .linkedValidation)

            let served = try await solutionNotebookData(
                for: assignment, setup: setup, db: app.db, testSetupsDirectory: app.testSetupsDirectory)
            let text = String(decoding: served, as: UTF8.self)
            #expect(text.contains("saved"))
            #expect(text.contains("bundled") == false)
        }
    }

    /// The zip stays a fallback for a setup that has no validation submission.
    @Test func theBundledSolutionIsUsedWhenNothingWasSaved() async throws {
        try await withWebRoutesApp { app in
            let (assignment, setup) = try await assignmentWithBundledSolution(id: "sol_prec_zip", on: app)

            let found = try #require(
                try await resolveSolution(
                    at: SolutionLocation(assignment), setup: setup, sources: SolutionSource.any,
                    db: app.db, testSetupsDirectory: app.testSetupsDirectory))
            #expect(found.source == .setupZip)
            #expect(String(decoding: found.data, as: UTF8.self).contains("bundled"))
        }
    }

    @Test func anEditFormSaveKeepsTheSavedSolution() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let (assignment, _) = try await assignmentWithBundledSolution(id: "sol_prec_form", on: app)
            try await saveSolution("saved", for: assignment, on: app)

            // An active runner, so the save's availability pre-check passes and
            // it reaches the step that picks the solution to validate.
            let profile = RunnerProfile()
            profile.runnerID = "runner-solution-precedence"
            profile.displayName = "Runner Solution Precedence"
            profile.platform = "linux"
            profile.architecture = "x86_64"
            profile.languageVersionsJSON = "[]"
            profile.capabilitiesJSON = "[]"
            profile.lastRegisteredAt = Date()
            profile.lastSeenAt = Date().addingTimeInterval(3600)
            profile.isActive = true
            try await profile.save(on: app.db)

            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "assignmentName": "Lab", "dueAt": ""], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            // The save re-validates; the run it links must use the saved
            // solution, not the zip's original one.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            let linkedID = try #require(reloaded.validationSubmissionID)
            let linked = try #require(try await APISubmission.find(linkedID, on: app.db))
            let text = try String(contentsOfFile: linked.zipPath, encoding: .utf8)
            #expect(text.contains("saved"))
            #expect(text.contains("bundled") == false)
        }
    }
}
