// Tests/APITests/TASaveEditTests.swift
//
// `POST /instructor/:assignmentID/edit/save` admits a TA, because a TA edits
// content. The same form carries fields that only an instructor may change:
// the title, the dates, the LEARN assessment, the submission method, the
// language and the class activity. A TA's Save that changes one of them is
// refused with 403 and writes nothing; a TA's Save that changes content only
// still succeeds, and does not close the assignment (#2484).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class TASaveEditTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ta-save")
    }

    private static let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","languageDeclared":true,\
        "requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    private static let cppManifest = """
        {"schemaVersion":1,"gradingMode":"worker","submissionMode":"uploadOnly","language":"cpp",\
        "languageDeclared":true,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],\
        "timeLimitSeconds":10}
        """
    private static let solutionJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[],"execution_count":null}]}
        """
    /// 2026-11-02 17:00 in America/Toronto, as the edit form shows it.
    private static let dueLocal = "2026-11-02T17:00"

    private struct Fixture {
        let assignment: APIAssignment
        let csrf: String
        let sessionCookie: String
    }

    /// An open assignment with a due date and a draft solution, and a user
    /// enrolled at `role` in its course.
    private func fixture(role: CourseRole, manifest: String = TASaveEditTests.manifest) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "TASAVE", name: "TA Save", mode: .closed)
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: "tasave_setup", courseID: courseID, manifest: manifest)
        let draftPath =
            try ensureDraftNotebookDirectory(
                testSetupsDirectory: app.testSetupsDirectory, setupID: "tasave_setup")
            + "solution.ipynb"
        try Data(Self.solutionJSON.utf8).write(to: URL(fileURLWithPath: draftPath))
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "tasave_setup", courseID: courseID, title: "Lab 1",
            dueAt: parseDueDate(Self.dueLocal), isOpen: true)

        let cookie = try await loginUser(username: "staff_user", password: "pw", role: "student", on: app)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "staff_user").first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role)
            .save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Fixture(assignment: assignment, csrf: csrf, sessionCookie: sessionCookie)
    }

    /// Posts the Save form with the stored values, changed by `overrides`.
    private func save(
        _ fixture: Fixture, _ overrides: [String: String] = [:],
        afterResponse: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        var fields = [
            "_csrf": fixture.csrf, "assignmentName": "Lab 1", "dueAt": Self.dueLocal,
            "startsAt": "", "assignmentLanguage": "python",
        ]
        fields.merge(overrides) { $1 }
        try await app.asyncTest(
            .POST, "/instructor/\(fixture.assignment.publicID)/edit/save",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fixture.sessionCookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: afterResponse)
    }

    private func stored(_ fixture: Fixture) async throws -> APIAssignment {
        try #require(try await APIAssignment.find(fixture.assignment.id, on: app.db))
    }

    @Test func taSaveThatChangesOnlyContentSucceedsAndDoesNotClose() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(role: .ta)
            try await save(fixture) { res in
                #expect(res.status == .seeOther)
                #expect(!(res.headers.first(name: .location) ?? "").contains("error="))
            }
            // The close is an instructor action, so a TA's Save writes live.
            #expect(try await stored(fixture).visibility != .closed)
        }
    }

    @Test(arguments: [
        ["assignmentName": "Lab 1 renamed"],
        ["dueAt": "2026-11-09T17:00"],
        ["startsAt": "2026-10-20T09:00"],
        ["gradeObjectID": "12345"],
        ["submissionMode": "uploadOnly"],
        ["assignmentLanguage": "r"],
        ["activityKind": "bestMetric"],
    ])
    func taSaveThatChangesAnInstructorOnlyFieldIsRefused(_ change: [String: String]) async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(role: .ta)
            let manifestBefore = try #require(
                try await APITestSetup.find("tasave_setup", on: app.db)
            ).manifest
            try await save(fixture, change) { res in
                #expect(res.status == .forbidden)
            }
            let after = try await stored(fixture)
            #expect(after.title == "Lab 1")
            #expect(after.dueAt == parseDueDate(Self.dueLocal))
            #expect(after.startsAt == nil)
            #expect(after.brightspaceGradeObjectID == nil)
            #expect(after.visibility != .closed)
            let manifestAfter = try #require(
                try await APITestSetup.find("tasave_setup", on: app.db)
            ).manifest
            #expect(manifestAfter == manifestBefore)
        }
    }

    @Test func instructorSaveCanChangeTheDueDateAndCloses() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(role: .instructor)
            try await save(fixture, ["dueAt": "2026-11-09T17:00"]) { res in
                #expect(res.status == .seeOther)
            }
            let after = try await stored(fixture)
            #expect(after.dueAt == parseDueDate("2026-11-09T17:00"))
            #expect(after.visibility == .closed)
        }
    }

    /// `persistSubmissionMode` reports the rule that `ManifestCoherence`
    /// gives, not always the upload + browser message.
    @Test func submissionModeRefusalReportsTheCoherenceReason() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(role: .instructor, manifest: Self.cppManifest)
            try await save(fixture, ["assignmentLanguage": "cpp", "submissionMode": "notebook"]) { res in
                #expect(res.status == .seeOther)
                let location = res.headers.first(name: .location)?.removingPercentEncoding ?? ""
                #expect(location.contains(requiresUploadOnlyMessage(.cpp)), "got: \(location)")
            }
        }
    }
}
