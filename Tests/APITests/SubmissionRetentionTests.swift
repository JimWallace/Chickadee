import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

/// Covers the submission-retention policy: archiving stamps `archived_at`,
/// the retention service counts submissions per course, and the Retention
/// report lists archived courses with Restore + (once eligible) Delete.
@Suite(.serialized) final class SubmissionRetentionTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-retention")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(
            username: "retention_admin", password: "testpassword", role: "admin", on: app)
    }

    private func csrfCookieAndToken(
        _ cookie: String, path: String = "/admin/retention"
    ) async throws -> (String, String) {
        let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
        return (boundCookie, token)
    }

    private let dayInSeconds: TimeInterval = 86_400

    // MARK: - Archiving stamps archived_at

    @Test func toggleCourseArchiveStampsAndClearsArchivedAt() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(on: app, code: "RET101", name: "Stamp Me")
            let courseID = try course.requireID()
            #expect(course.archivedAt == nil)

            func postArchive() async throws {
                let (boundCookie, token) = try await csrfCookieAndToken(
                    cookie, path: "/admin/courses/\(courseID.uuidString)")
                try await app.asyncTest(
                    .POST, "/admin/courses/\(courseID.uuidString)/archive",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: boundCookie)
                        try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                    },
                    afterResponse: { res in #expect(res.status == .seeOther) })
            }

            // Archive → stamped.
            try await postArchive()
            let archived = try await APICourse.find(courseID, on: app.db)
            #expect(archived?.isArchived == true)
            #expect(archived?.archivedAt != nil)

            // Un-archive → cleared (retention clock reset).
            try await postArchive()
            let unarchived = try await APICourse.find(courseID, on: app.db)
            #expect(unarchived?.isArchived == false)
            #expect(unarchived?.archivedAt == nil)
        }
    }

    // MARK: - Service: counting

    @Test func submissionCountsByCourseCountsAcrossSetups() async throws {
        try await withApp(app) { _ in
            let student = try await makeTestUser(on: app, username: "ret_count_student", role: "student")
            let studentID = try student.requireID()

            let course = try await makeTestCourse(on: app, code: "RETC1", name: "Counted")
            let courseID = try course.requireID()
            _ = try await makeTestSetup(on: app, id: "ret_count_s1", courseID: courseID, withNotebook: false)
            _ = try await makeTestSetup(on: app, id: "ret_count_s2", courseID: courseID, withNotebook: false)
            _ = try await makeTestSubmission(on: app, id: "ret_c_sub1", setupID: "ret_count_s1", userID: studentID)
            _ = try await makeTestSubmission(on: app, id: "ret_c_sub2", setupID: "ret_count_s1", userID: studentID)
            _ = try await makeTestSubmission(on: app, id: "ret_c_sub3", setupID: "ret_count_s2", userID: studentID)

            // A second course's submission must not bleed into the count.
            let other = try await makeTestCourse(on: app, code: "RETC2", name: "Other")
            let otherID = try other.requireID()
            _ = try await makeTestSetup(on: app, id: "ret_count_o1", courseID: otherID, withNotebook: false)
            _ = try await makeTestSubmission(on: app, id: "ret_c_other", setupID: "ret_count_o1", userID: studentID)

            let counts = try await SubmissionRetentionService.submissionCountsByCourse(
                courseIDs: [courseID, otherID], on: app.db)
            #expect(counts[courseID] == 3)
            #expect(counts[otherID] == 1)
        }
    }

    // MARK: - Report page

    @Test func retentionPageListsArchivedCoursesAndMarksEligible() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            let eligible = try await makeTestCourse(
                on: app, code: "RETPAGEELIG", name: "Eligible Course", archived: true)
            eligible.archivedAt = Date().addingTimeInterval(-400 * dayInSeconds)
            try await eligible.save(on: app.db)

            let pending = try await makeTestCourse(
                on: app, code: "RETPAGEPEND", name: "Pending Course", archived: true)
            pending.archivedAt = Date()
            try await pending.save(on: app.db)

            _ = try await makeTestCourse(on: app, code: "RETPAGEACTIVE", name: "Active Course")

            // Resolve IDs up front: a `try` inside the #expect string
            // interpolation isn't handled by the macro expansion.
            let eligibleID = try eligible.requireID().uuidString
            let pendingID = try pending.requireID().uuidString
            let eligibleDeleteURL = "/admin/courses/\(eligibleID)/delete"
            let pendingDeleteURL = "/admin/courses/\(pendingID)/delete"
            let pendingRestoreURL = "/admin/courses/\(pendingID)/archive"

            try await app.asyncTest(
                .GET, "/admin/retention",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    // Archived courses listed.
                    #expect(body.contains(">RETPAGEELIG<"))
                    #expect(body.contains(">RETPAGEPEND<"))
                    // Active (non-archived) course is not subject to retention yet.
                    #expect(body.contains(">RETPAGEACTIVE<") == false)
                    // Eligible course offers the permanent Delete action.
                    #expect(body.contains(eligibleDeleteURL))
                    // Pending course can be restored but not yet deleted.
                    #expect(body.contains(pendingRestoreURL))
                    #expect(body.contains(pendingDeleteURL) == false)
                    // Retention tab is active.
                    #expect(body.contains("href=\"/admin/retention\" aria-current=\"page\""))
                })
        }
    }
}
