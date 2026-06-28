// Tests/APITests/ArchivedCourseWriteRouteTests.swift
//
// Route-level coverage for the archived-course write block (Slice A of #417,
// docs/multi-course-roles.md). The assignment editor's mutating endpoints
// authorize against the *assignment's own* course via
// `loadAssignmentAndSetupForWrite` → `requireCourseWriteAccess`, so a
// per-course instructor can neither edit an archived course's content nor
// drive an edit against another course by URL. The `/instructor` group
// middleware only sees the caller's *active* course, so this is the layer
// that catches a write whose target course differs from (or is archived
// relative to) the active one.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ArchivedCourseWriteRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-archived-wr")
    }

    /// Creates a course + test setup + published assignment and returns the
    /// course UUID and the assignment's public ID.
    private func makeCourseAssignment(
        code: String, archived: Bool, enrollmentMode: CourseEnrollmentMode
    ) async throws -> (courseID: UUID, assignmentID: String) {
        let courseID = UUID()
        let course = APICourse(id: courseID, code: code, name: code, enrollmentMode: enrollmentMode)
        course.isArchived = archived
        try await course.save(on: app.db)

        let setupID = "awr_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try arMakeZip(at: zipPath, entries: [(".placeholder", "x"), ("publictest_a.py", "passed('a')\n")])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_a.py"}],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)

        let assignment = APIAssignment(
            testSetupID: setupID, title: code,
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID
        )
        try await assignment.save(on: app.db)
        return (courseID, assignment.publicID)
    }

    /// A per-course instructor whose *active* course is a normal (non-archived)
    /// course may edit that course's assignment, but a `PUT /suite` aimed by URL
    /// at an *archived* course they also instruct is rejected with 403. The
    /// active-course edit succeeding in the same test confirms the setup is
    /// sound, so the archived 403 is attributable to the archived block — not a
    /// stray middleware denial.
    @Test func putSuite_blockedOnArchivedCourseEvenForItsInstructor() async throws {
        try await withApp(app) { _ in
            // Active, non-archived course (.auto → the instructor auto-enrols as
            // a per-course instructor and it becomes their active course, the
            // same pattern SuiteRouteTests relies on).
            let active = try await makeCourseAssignment(
                code: "AWRX", archived: false, enrollmentMode: .auto)
            // Archived course with an assignment; the same instructor is enrolled
            // here as a per-course instructor.
            let archived = try await makeCourseAssignment(
                code: "AWRY", archived: true, enrollmentMode: .closed)

            let cookie = try await loginUser(
                username: "awr_inst", password: "pw", role: "instructor", on: app)
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "awr_inst").first())
            try await APICourseEnrollment(
                userID: try user.requireID(), courseID: archived.courseID, role: .instructor
            ).save(on: app.db)

            let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

            // Sanity: editing the active (non-archived) course's assignment works.
            try await app.asyncTest(
                .PUT, "/instructor/\(active.assignmentID)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"items":[]}"#)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "active-course edit should succeed: \(res.body.string)")
                })

            // The block: editing the archived course's assignment by URL is 403.
            try await app.asyncTest(
                .PUT, "/instructor/\(archived.assignmentID)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"items":[]}"#)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "archived-course edit must be blocked, got \(res.status): \(res.body.string)")
                })
        }
    }
}
