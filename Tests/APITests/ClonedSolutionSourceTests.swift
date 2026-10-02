// Tests/APITests/ClonedSolutionSourceTests.swift
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
        let app = try await makeTestApp()
        try await withApp(app) { app in
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
}
