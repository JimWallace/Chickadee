// The web script routes re-validate an assignment on the server (#2259, item 1).
//
// The page used to own this step. After a suite-table delete it sent
// `PUT /suite`, which re-validated; after a support-file delete it sent nothing,
// so the assignment kept its old `validationStatus` while a test that imported
// the deleted helper failed for every student. The MCP `delete_support_file`
// tool re-validated all along.
//
// The observable effect is the same one `putSuiteSetsNoRunnerStatusWhenNoCompatibleRunner`
// uses: with a reference solution on file and no runner registered, a scheduled
// re-validation sets `validationStatus` to "no-runner". An edit that skips the
// step leaves the status as it was.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct WebContentEditEffectsTests {

    private static let publicID = "WCE001"
    private static let setupID = "setup_web_content_edit"

    /// Seeds an assignment whose zip holds one test and one support file, with
    /// a reference solution on file so that a re-validation reaches the runner
    /// check. Returns the session cookie and CSRF token for the instructor.
    private func seed(on app: Application) async throws -> (cookie: String, csrf: String) {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let cookie = try await arLoginAsInstructor(on: app)

        let zipPath = app.testSetupsDirectory + "\(Self.setupID).zip"
        try await arMakeZip(
            at: zipPath,
            entries: [("test_q1.py", "import helper\n"), ("helper.py", "VALUE = 1\n")])
        let manifest = """
            {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(
            id: Self.setupID, manifest: manifest, zipPath: zipPath,
            notebookPath: app.testSetupsDirectory + "notebooks/\(Self.setupID)/assignment.ipynb",
            courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            publicID: Self.publicID, testSetupID: Self.setupID,
            title: "Web content edit", dueAt: nil, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let solutionPath = app.submissionsDirectory + "web_content_edit_solution.ipynb"
        try #require(defaultNotebookData(title: "Solution", language: nil)).write(
            to: URL(fileURLWithPath: solutionPath))
        let validation = APISubmission(
            id: "sub_web_content_edit_validation", testSetupID: Self.setupID,
            zipPath: solutionPath, attemptNumber: 1, status: "complete",
            filename: "solution.ipynb", userID: nil, kind: APISubmission.Kind.validation)
        try await validation.save(on: app.db)
        assignment.validationSubmissionID = "sub_web_content_edit_validation"
        assignment.validationStatus = "passed"
        try await assignment.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(Self.publicID)/edit", cookie: cookie, on: app)
        return (sessionCookie, csrf)
    }

    private func send(
        _ method: HTTPMethod, _ path: String, json: String?, auth: (cookie: String, csrf: String),
        expecting status: HTTPStatus, on app: Application
    ) async throws {
        try await app.asyncTest(
            method, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: auth.cookie)
                req.headers.add(name: "x-csrf-token", value: auth.csrf)
                if let json {
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: json)
                }
            },
            afterResponse: { res in
                #expect(res.status == status, "\(res.body.string)")
            })
    }

    private func validationStatus(on app: Application) async throws -> String? {
        try await APIAssignment.query(on: app.db)
            .filter(\.$publicID == Self.publicID)
            .first()?
            .validationStatus
    }

    @Test func deletingASupportFileRevalidates() async throws {
        try await withAssignmentRoutesApp { app in
            let auth = try await seed(on: app)
            try await send(
                .DELETE, "/instructor/\(Self.publicID)/scripts/helper.py", json: nil,
                auth: auth, expecting: .noContent, on: app)
            #expect(try await validationStatus(on: app) == "no-runner")
        }
    }

    @Test func creatingASupportFileRevalidates() async throws {
        try await withAssignmentRoutesApp { app in
            let auth = try await seed(on: app)
            try await send(
                .POST, "/instructor/\(Self.publicID)/scripts",
                json: #"{"filename":"data.py","content":"ROWS = 3\n","tier":"support"}"#,
                auth: auth, expecting: .created, on: app)
            #expect(try await validationStatus(on: app) == "no-runner")
        }
    }

    @Test func editingASupportFileRevalidates() async throws {
        try await withAssignmentRoutesApp { app in
            let auth = try await seed(on: app)
            try await send(
                .PUT, "/instructor/\(Self.publicID)/scripts/helper.py",
                json: #"{"content":"VALUE = 2\n"}"#,
                auth: auth, expecting: .noContent, on: app)
            #expect(try await validationStatus(on: app) == "no-runner")
        }
    }

    /// The live editor does not close an open assignment; only the MCP tools
    /// do. The shared effects must not change that.
    @Test func aWebScriptEditLeavesAnOpenAssignmentOpen() async throws {
        try await withAssignmentRoutesApp { app in
            let auth = try await seed(on: app)
            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$publicID == Self.publicID).first())
            assignment.visibility = .open
            try await assignment.save(on: app.db)

            try await send(
                .DELETE, "/instructor/\(Self.publicID)/scripts/helper.py", json: nil,
                auth: auth, expecting: .noContent, on: app)
            let after = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$publicID == Self.publicID).first())
            #expect(after.visibility == .open)
        }
    }
}
