// Tests/APITests/ArchivedCourseStudentActionRouteTests.swift
//
// Route-level coverage for the archived-course write block on the per-student
// instructor actions (#417, follow-up to Slice A). Slice A wired the assignment
// *editor* mutations through `loadAssignmentAndSetupForWrite`; the per-student
// dashboard actions (retest, grade override, notebook reset) and the clone
// endpoint were explicitly deferred because they resolve their course
// differently. This slice closes that gap: those handlers now authorize against
// the *assignment's own* course via `requireCourseWriteAccess`, so a per-course
// instructor can neither retest into an archived course nor drive the action
// against another course by URL — the `/instructor` group middleware only sees
// the caller's *active* course, so it can't catch either.
//
// `POST /instructor/:assignmentID/retest` (retest-all) stands in for the family:
// every patched handler shares the same `requireCourseWriteAccess` gate, so one
// route-level proof plus the helper-level matrix in `CourseEnrollmentRoleTests`
// covers the behaviour without re-staging student submissions per endpoint.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ArchivedCourseStudentActionRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-archived-sa")
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

        let setupID = "asa_\(UUID().uuidString.prefix(8))"
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
    /// course may retest that course's assignment, but a retest-all aimed by URL
    /// at an *archived* course they also instruct is rejected with 403. The
    /// active-course retest succeeding in the same test confirms the setup is
    /// sound, so the archived 403 is attributable to the archived block — not a
    /// stray middleware denial.
    @Test func retestAll_blockedOnArchivedCourseEvenForItsInstructor() async throws {
        try await withApp(app) { _ in
            // Active, non-archived course (.auto → the instructor auto-enrols as
            // a per-course instructor and it becomes their active course).
            let active = try await makeCourseAssignment(
                code: "ASAX", archived: false, enrollmentMode: .auto)
            // Archived course with an assignment; the same instructor is enrolled
            // here as a per-course instructor.
            let archived = try await makeCourseAssignment(
                code: "ASAY", archived: true, enrollmentMode: .closed)

            let cookie = try await loginUser(
                username: "asa_inst", password: "pw", role: "instructor", on: app)
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "asa_inst").first())
            try await APICourseEnrollment(
                userID: try user.requireID(), courseID: archived.courseID, role: .instructor
            ).save(on: app.db)

            let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

            // Sanity: retesting the active (non-archived) course's assignment
            // works (redirects back).
            try await app.asyncTest(
                .POST, "/instructor/\(active.assignmentID)/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                },
                afterResponse: { res in
                    #expect(
                        res.status == .seeOther,
                        "active-course retest should succeed: \(res.status) \(res.body.string)")
                })

            // The block: retesting the archived course's assignment by URL is 403.
            try await app.asyncTest(
                .POST, "/instructor/\(archived.assignmentID)/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "archived-course retest must be blocked, got \(res.status): \(res.body.string)")
                })
        }
    }
}
