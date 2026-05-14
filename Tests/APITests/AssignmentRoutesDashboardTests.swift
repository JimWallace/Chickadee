// Tests/APITests/AssignmentRoutesDashboardTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AssignmentRoutesDashboardTests: AssignmentRoutesTestCase {

    func testCloseExpiredAssignmentsClosesOnlyEligibleAssignments() async throws {
        _ = try await insertSetup(id: "setup_deadline_close")
        let overdue = try await insertAssignment(
            testSetupID: "setup_deadline_close",
            title: "Overdue",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60)
        )

        _ = try await insertSetup(id: "setup_deadline_open")
        let noDeadline = try await insertAssignment(
            testSetupID: "setup_deadline_open",
            title: "No Deadline",
            isOpen: true
        )

        _ = try await insertSetup(id: "setup_deadline_override")
        let overridden = try await insertAssignment(
            testSetupID: "setup_deadline_override",
            title: "Override",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60),
            deadlineOverrideActive: true
        )

        let closedCount = try await closeExpiredAssignments(on: app.db, logger: app.logger)
        XCTAssertEqual(closedCount, 1)

        let overdueReloadedOptional = try await APIAssignment.find(overdue.id, on: app.db)
        XCTAssertNotNil(overdueReloadedOptional)
        let overdueReloaded = overdueReloadedOptional!
        XCTAssertFalse(overdueReloaded.isOpen)

        let noDeadlineReloadedOptional = try await APIAssignment.find(noDeadline.id, on: app.db)
        XCTAssertNotNil(noDeadlineReloadedOptional)
        let noDeadlineReloaded = noDeadlineReloadedOptional!
        XCTAssertTrue(noDeadlineReloaded.isOpen)

        let overriddenReloadedOptional = try await APIAssignment.find(overridden.id, on: app.db)
        XCTAssertNotNil(overriddenReloadedOptional)
        let overriddenReloaded = overriddenReloadedOptional!
        XCTAssertTrue(overriddenReloaded.isOpen)
    }

    func testInstructorCanReopenPastDueAssignmentWithOverride() async throws {
        _ = try await insertSetup(id: "setup_reopen_deadline")
        let assignment = try await insertAssignment(
            testSetupID: "setup_reopen_deadline",
            title: "Past Due",
            isOpen: false,
            dueAt: Date().addingTimeInterval(-60)
        )
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(
            .POST, "/instructor/\(assignment.publicID)/open",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            })

        let reopenedOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(reopenedOptional)
        let reopened = reopenedOptional!
        XCTAssertTrue(reopened.isOpen)
        XCTAssertEqual(reopened.deadlineOverrideActive, true)

        _ = try await closeExpiredAssignments(on: app.db, logger: app.logger)
        let stillOpenOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(stillOpenOptional)
        let stillOpen = stillOpenOptional!
        XCTAssertTrue(stillOpen.isOpen)
    }

    // MARK: - GET /instructor

    func testStudentCannotAccessAssignments() async throws {
        let cookie = try await loginAsStudent()
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    func testInstructorCanAccessAssignments() async throws {
        let cookie = try await loginAsInstructor()
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                // 500 expected because Leaf is not configured in tests — but middleware passed (not 401/403).
                XCTAssertNotEqual(res.status, .unauthorized)
                XCTAssertNotEqual(res.status, .forbidden)
            })
    }

    func testAssignmentsPageUsesDedicatedEnrollCSVPageLink() async throws {
        _ = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("href=\"/instructor/enroll-csv\""))
                XCTAssertFalse(html.contains("id=\"enroll-csv-file\""))
            })
    }

    func testAssignmentsPageDefaultsEnrolledStudentsToMostRecentLastSeenFirst() async throws {
        _ = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsInstructor()
        let now = Date()

        let never = try await insertStudent(username: "never_seen_student", displayName: "Never Seen")
        try await enrollStudentInTestCourse(never)

        let older = try await insertStudent(username: "older_seen_student", displayName: "Older Seen")
        older.lastSeenAt = now.addingTimeInterval(-3600)
        try await older.save(on: app.db)
        try await enrollStudentInTestCourse(older)

        let recent = try await insertStudent(username: "recent_seen_student", displayName: "Recent Seen")
        recent.lastSeenAt = now
        try await recent.save(on: app.db)
        try await enrollStudentInTestCourse(recent)

        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("id=\"enrolled-students-table\""))
                XCTAssertTrue(html.contains("var sortCol = 3;"))
                XCTAssertTrue(html.contains("var sortAsc = false;"))
                let recentIndex = try XCTUnwrap(html.range(of: "recent_seen_student")?.lowerBound)
                let olderIndex = try XCTUnwrap(html.range(of: "older_seen_student")?.lowerBound)
                let neverIndex = try XCTUnwrap(html.range(of: "never_seen_student")?.lowerBound)
                XCTAssertLessThan(recentIndex, olderIndex)
                XCTAssertLessThan(olderIndex, neverIndex)
            })
    }

    /// Regression guard for v0.4.126 — admin/instructor users enrolled in a
    /// course (a common pattern: instructor enrolls themselves to test their
    /// own assignment via the same flow as a student) used to inflate the
    /// per-assignment "X / Y students submitted" badge on the `/instructor`
    /// dashboard.  Both counts now filter to enrolled users with role ==
    /// "student"; this test enrolls 2 students + 1 instructor + 1 admin in
    /// the test course, has each of them submit one student-kind submission,
    /// and asserts the badge for the assignment row reads "2 / 2" (not
    /// "4 / 4", which is what it showed pre-fix).
    func testInstructorDashboardBadgeCountsStudentsOnly() async throws {
        _ = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsInstructor()

        // Two real students, both enrolled.
        let s1 = try await insertStudent(username: "stat_s1", displayName: "Student One")
        try await enrollStudentInTestCourse(s1)
        let s2 = try await insertStudent(username: "stat_s2", displayName: "Student Two")
        try await enrollStudentInTestCourse(s2)

        // One extra instructor + one admin, also enrolled in the same
        // course.  These are the users whose submissions should NOT be
        // reflected in either side of the badge.
        let i1 = try await insertUser(
            username: "stat_i1", role: "instructor",
            displayName: "Helper Instructor")
        try await enrollStudentInTestCourse(i1)
        let a1 = try await insertUser(
            username: "stat_a1", role: "admin",
            displayName: "Helper Admin")
        try await enrollStudentInTestCourse(a1)

        // Setup + assignment.
        try await insertSetup(id: "setup_dashboard_filter")
        let assignment = try await insertAssignment(
            testSetupID: "setup_dashboard_filter",
            title: "Mixed-Role Assignment",
            isOpen: true
        )

        // One student-kind submission per user — same path the instructor
        // would hit when testing their own assignment via the submit form.
        try await insertSubmission(
            id: "sub_s1", testSetupID: "setup_dashboard_filter",
            userID: try s1.requireID())
        try await insertSubmission(
            id: "sub_s2", testSetupID: "setup_dashboard_filter",
            userID: try s2.requireID())
        try await insertSubmission(
            id: "sub_i1", testSetupID: "setup_dashboard_filter",
            userID: try i1.requireID())
        try await insertSubmission(
            id: "sub_a1", testSetupID: "setup_dashboard_filter",
            userID: try a1.requireID())

        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string

                // The leaf template renders the badge as
                //   <span title="<X> / <Y> students submitted"><X> / <Y></span>
                // We assert against the title (a unique, structural attribute)
                // so the test doesn't depend on layout cosmetics.
                XCTAssertTrue(
                    html.contains("title=\"2 / 2 students submitted\""),
                    "Per-assignment badge should read '2 / 2 students submitted' "
                        + "(only enrolled students count); admin/instructor "
                        + "submissions and enrollments must be filtered out. "
                        + "Assignment publicID=\(assignment.publicID)"
                )
                XCTAssertFalse(
                    html.contains("title=\"4 / 4 students submitted\""),
                    "Pre-v0.4.126 shape: admin/instructor inflated both X and Y. "
                        + "The fix in AssignmentRoutes.swift list() must scope both "
                        + "submittedStudentCount and enrolledStudentCount to "
                        + "enrolledStudentIDs."
                )
            })
    }

    /// Dashboard card "Students With Browser Errors" counts distinct
    /// students who posted a client-side diagnostic (preflight or watchdog
    /// failure) on one of this course's test setups within the 24h window.
    /// Diagnostics outside the window, on other courses' setups, or with
    /// a null test_setup_id (stale) must not inflate the count.
    func testInstructorDashboardCountsStudentsWithBrowserErrors() async throws {
        let cookie = try await loginAsInstructor()

        let s1 = try await insertStudent(username: "browserErr_s1")
        try await enrollStudentInTestCourse(s1)
        let s2 = try await insertStudent(username: "browserErr_s2")
        try await enrollStudentInTestCourse(s2)
        let s3 = try await insertStudent(username: "browserErr_s3")
        try await enrollStudentInTestCourse(s3)

        try await insertSetup(id: "setup_browser_err")
        try await insertAssignment(
            testSetupID: "setup_browser_err",
            title: "Browser-error Metric Test",
            isOpen: true
        )

        // s1 hit a preflight failure right now → counts.
        let d1 = APIClientDiagnostic(
            userID: try s1.requireID(),
            testSetupID: "setup_browser_err",
            kind: "preflight_fail",
            failedChecks: "serviceWorker",
            userAgent: "TestUA"
        )
        try await d1.save(on: app.db)

        // s2 hit a watchdog timeout right now → counts.
        let d2 = APIClientDiagnostic(
            userID: try s2.requireID(),
            testSetupID: "setup_browser_err",
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await d2.save(on: app.db)

        // s1 again, just to verify deduplication-by-user in the metric.
        let d1b = APIClientDiagnostic(
            userID: try s1.requireID(),
            testSetupID: "setup_browser_err",
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await d1b.save(on: app.db)

        // s3 hit a diagnostic 48h ago → outside the window, must NOT count.
        let staleStudent = try await insertStudent(username: "browserErr_stale")
        try await enrollStudentInTestCourse(staleStudent)
        let dStale = APIClientDiagnostic(
            userID: try staleStudent.requireID(),
            testSetupID: "setup_browser_err",
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await dStale.save(on: app.db)
        // Manually back-date so it falls outside the 24h window.
        dStale.createdAt = Date().addingTimeInterval(-48 * 60 * 60)
        try await dStale.save(on: app.db)

        // s3 hit a diagnostic with a null test_setup_id → unattributable,
        // must NOT count.
        let dOrphan = APIClientDiagnostic(
            userID: try s3.requireID(),
            testSetupID: nil,
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await dOrphan.save(on: app.db)

        // Expected: 2 distinct students (s1, s2).
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string

                let pattern = #"Students With Browser Errors</div>\s*<div class="diagnostic-value">(\d+)</div>"#
                let re = try NSRegularExpression(pattern: pattern)
                let nsr = NSRange(html.startIndex..., in: html)
                guard let match = re.firstMatch(in: html, range: nsr),
                    let valueRange = Range(match.range(at: 1), in: html)
                else {
                    XCTFail("Could not locate 'Students With Browser Errors' metric card in dashboard HTML")
                    return
                }
                XCTAssertEqual(
                    String(html[valueRange]), "2",
                    "Expected 2 students (s1 + s2 with recent diagnostics).  "
                        + "Out-of-window diagnostics and diagnostics with a null "
                        + "test_setup_id must not inflate the count."
                )
            })
    }
}
