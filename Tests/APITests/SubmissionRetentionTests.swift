import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

/// Covers the submission-retention policy: archiving stamps `archived_at`,
/// the retention service counts/purges submission data, and the manual
/// purge route enforces eligibility server-side.
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

    // MARK: - Service: purging

    @Test func purgeSubmissionsRemovesSubmissionDataButKeepsCourse() async throws {
        try await withApp(app) { _ in
            let student = try await makeTestUser(on: app, username: "ret_purge_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "RETP1", name: "Purge Me", archived: true)
            let courseID = try course.requireID()
            _ = try await makeTestSetup(on: app, id: "ret_purge_setup", courseID: courseID, withNotebook: false)
            _ = try await makeTestAssignment(on: app, testSetupID: "ret_purge_setup", courseID: courseID)
            let submission = try await makeTestSubmission(
                on: app, id: "ret_purge_sub", setupID: "ret_purge_setup", userID: studentID)
            _ = try await makeTestResult(on: app, submissionID: try submission.requireID())
            #expect(FileManager.default.fileExists(atPath: submission.zipPath))

            let deleted = try await SubmissionRetentionService.purgeSubmissions(
                forCourseID: courseID, on: app.db)
            #expect(deleted == 1)

            // Submission data gone…
            let subCount = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == "ret_purge_setup").count()
            let resultCount = try await APIResult.query(on: app.db).count()
            #expect(subCount == 0)
            #expect(resultCount == 0)
            #expect(FileManager.default.fileExists(atPath: submission.zipPath) == false)

            // …course, setup, assignment, and user preserved.
            #expect(try await APICourse.find(courseID, on: app.db) != nil)
            #expect(try await APITestSetup.find("ret_purge_setup", on: app.db) != nil)
            let assignmentCount = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == courseID).count()
            #expect(assignmentCount == 1)
            #expect(try await APIUser.find(studentID, on: app.db) != nil)
        }
    }

    // MARK: - Route: eligibility guard

    @Test func purgeRouteRejectsCourseStillWithinRetentionWindow() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let student = try await makeTestUser(on: app, username: "ret_recent_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "RETR1", name: "Recent Archive", archived: true)
            let courseID = try course.requireID()
            // Archived just now → within the 365-day default window.
            course.archivedAt = Date()
            try await course.save(on: app.db)
            _ = try await makeTestSetup(on: app, id: "ret_recent_setup", courseID: courseID, withNotebook: false)
            _ = try await makeTestSubmission(
                on: app, id: "ret_recent_sub", setupID: "ret_recent_setup", userID: studentID)

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/purge-submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    // Redirects back to the report with an error flash.
                    #expect(res.headers.first(name: .location)?.contains("/admin/retention") == true)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })

            // Submission must survive — the window hasn't elapsed.
            let subCount = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == "ret_recent_setup").count()
            #expect(subCount == 1)
        }
    }

    @Test func purgeRoutePurgesEligibleCourseAndWritesAudit() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let student = try await makeTestUser(on: app, username: "ret_old_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "RETO1", name: "Old Archive", archived: true)
            let courseID = try course.requireID()
            // Archived 400 days ago → past the 365-day default window.
            course.archivedAt = Date().addingTimeInterval(-400 * dayInSeconds)
            try await course.save(on: app.db)
            _ = try await makeTestSetup(on: app, id: "ret_old_setup", courseID: courseID, withNotebook: false)
            let submission = try await makeTestSubmission(
                on: app, id: "ret_old_sub", setupID: "ret_old_setup", userID: studentID)
            _ = try await makeTestResult(on: app, submissionID: try submission.requireID())

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/purge-submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("ok=") == true)
                })

            let subCount = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == "ret_old_setup").count()
            #expect(subCount == 0)
            #expect(FileManager.default.fileExists(atPath: submission.zipPath) == false)
            // Course itself is preserved.
            #expect(try await APICourse.find(courseID, on: app.db) != nil)

            let purgeAudits = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == "submission.retention_purged").all()
            #expect(purgeAudits.count == 1)
            #expect(purgeAudits.first?.targetID == courseID.uuidString)
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
            let eligiblePurgeURL = "/admin/courses/\(try eligible.requireID().uuidString)/purge-submissions"
            let pendingPurgeURL = "/admin/courses/\(try pending.requireID().uuidString)/purge-submissions"

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
                    // Eligible course offers the purge action.
                    #expect(body.contains(eligiblePurgeURL))
                    // Pending course does not.
                    #expect(body.contains(pendingPurgeURL) == false)
                    // Retention tab is active.
                    #expect(body.contains("href=\"/admin/retention\" aria-current=\"page\""))
                })
        }
    }
}
