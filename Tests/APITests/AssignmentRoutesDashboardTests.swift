// Tests/APITests/AssignmentRoutesDashboardTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AssignmentRoutesDashboardTests {

    @Test func closeExpiredAssignmentsClosesOnlyEligibleAssignments() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await arInsertSetup(id: "setup_deadline_close", on: app)
            let overdue = try await arInsertAssignment(
                testSetupID: "setup_deadline_close",
                title: "Overdue",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60), on: app
            )

            _ = try await arInsertSetup(id: "setup_deadline_open", on: app)
            let noDeadline = try await arInsertAssignment(
                testSetupID: "setup_deadline_open",
                title: "No Deadline",
                isOpen: true, on: app
            )

            _ = try await arInsertSetup(id: "setup_deadline_override", on: app)
            let overridden = try await arInsertAssignment(
                testSetupID: "setup_deadline_override",
                title: "Override",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60),
                deadlineOverrideActive: true, on: app
            )

            let closedCount = try await closeExpiredAssignments(on: app.db, logger: app.logger)
            #expect(closedCount == 1)

            let overdueReloadedOptional = try await APIAssignment.find(overdue.id, on: app.db)
            #expect(overdueReloadedOptional != nil)
            let overdueReloaded = try #require(overdueReloadedOptional)
            #expect(overdueReloaded.isOpen == false)

            let noDeadlineReloadedOptional = try await APIAssignment.find(noDeadline.id, on: app.db)
            #expect(noDeadlineReloadedOptional != nil)
            let noDeadlineReloaded = try #require(noDeadlineReloadedOptional)
            #expect(noDeadlineReloaded.isOpen)

            let overriddenReloadedOptional = try await APIAssignment.find(overridden.id, on: app.db)
            #expect(overriddenReloadedOptional != nil)
            let overriddenReloaded = try #require(overriddenReloadedOptional)
            #expect(overriddenReloaded.isOpen)

        }
    }

    @Test func openScheduledAssignmentsOpensOnlyEligibleAssignments() async throws {
        try await withAssignmentRoutesApp { app in
            // Open date already passed, validation passed, no/future due → opens.
            _ = try await arInsertSetup(id: "setup_open_due", on: app)
            let ready = try await arInsertAssignment(
                testSetupID: "setup_open_due", title: "Ready",
                isOpen: false,
                dueAt: Date().addingTimeInterval(86_400),
                startsAt: Date().addingTimeInterval(-60),
                validationStatus: "passed", on: app
            )

            // Open date still in the future → stays closed.
            _ = try await arInsertSetup(id: "setup_open_future", on: app)
            let future = try await arInsertAssignment(
                testSetupID: "setup_open_future", title: "Future",
                isOpen: false,
                startsAt: Date().addingTimeInterval(86_400),
                validationStatus: "passed", on: app
            )

            // Open date passed but validation not passed → stays closed.
            _ = try await arInsertSetup(id: "setup_open_pending", on: app)
            let pending = try await arInsertAssignment(
                testSetupID: "setup_open_pending", title: "Pending",
                isOpen: false,
                startsAt: Date().addingTimeInterval(-60),
                validationStatus: "pending", on: app
            )

            // Whole window already in the past (due also passed) → stays closed.
            _ = try await arInsertSetup(id: "setup_open_pastdue", on: app)
            let pastDue = try await arInsertAssignment(
                testSetupID: "setup_open_pastdue", title: "Past window",
                isOpen: false,
                dueAt: Date().addingTimeInterval(-60),
                startsAt: Date().addingTimeInterval(-120),
                validationStatus: "passed", on: app
            )

            let openedCount = try await openScheduledAssignments(on: app.db, logger: app.logger)
            #expect(openedCount == 1)

            let readyReloaded = try #require(try await APIAssignment.find(ready.id, on: app.db))
            #expect(readyReloaded.isOpen)
            #expect(readyReloaded.startsAt == nil, "Open date is consumed once it fires")

            let futureReloaded = try #require(try await APIAssignment.find(future.id, on: app.db))
            #expect(futureReloaded.isOpen == false)
            #expect(futureReloaded.startsAt != nil)

            let pendingReloaded = try #require(try await APIAssignment.find(pending.id, on: app.db))
            #expect(pendingReloaded.isOpen == false, "Must not auto-open before validation passes")

            let pastDueReloaded = try #require(try await APIAssignment.find(pastDue.id, on: app.db))
            #expect(pastDueReloaded.isOpen == false, "Must not open a window whose due date already passed")
        }
    }

    @Test func openSweepDoesNotReopenAfterScheduleConsumed() async throws {
        try await withAssignmentRoutesApp { app in
            // Mirrors the state after auto-open + a manual close: isOpen false,
            // startsAt already cleared.  The sweep must leave it closed.
            _ = try await arInsertSetup(id: "setup_open_consumed", on: app)
            let closed = try await arInsertAssignment(
                testSetupID: "setup_open_consumed", title: "Consumed",
                isOpen: false,
                dueAt: Date().addingTimeInterval(86_400),
                startsAt: nil,
                validationStatus: "passed", on: app
            )

            let openedCount = try await openScheduledAssignments(on: app.db, logger: app.logger)
            #expect(openedCount == 0)
            let reloaded = try #require(try await APIAssignment.find(closed.id, on: app.db))
            #expect(reloaded.isOpen == false)
        }
    }

    @Test func closeExpiredAssignmentsKeepsAssignmentsWithActiveExtensionsOpen() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await arInsertSetup(id: "setup_ext_keepopen", on: app)
            let extended = try await arInsertAssignment(
                testSetupID: "setup_ext_keepopen",
                title: "Extended overdue",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60), on: app
            )
            let student = try await arInsertStudent(username: "keepopen_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await APIAssignmentExtension(
                assignmentID: try extended.requireID(),
                userID: try student.requireID(),
                extendedDueAt: Date().addingTimeInterval(86_400)
            ).save(on: app.db)

            // A second overdue assignment with no extension must still close.
            _ = try await arInsertSetup(id: "setup_noext_close", on: app)
            let plain = try await arInsertAssignment(
                testSetupID: "setup_noext_close",
                title: "Plain overdue",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60), on: app
            )

            let closedCount = try await closeExpiredAssignments(on: app.db, logger: app.logger)
            #expect(closedCount == 1, "Only the assignment without an active extension should close")

            let extendedReloaded = try #require(try await APIAssignment.find(extended.id, on: app.db))
            #expect(extendedReloaded.isOpen, "Assignment with an active extension must stay open")
            let plainReloaded = try #require(try await APIAssignment.find(plain.id, on: app.db))
            #expect(plainReloaded.isOpen == false, "Assignment with no extension must auto-close")
        }
    }

    @Test func instructorCanReopenPastDueAssignmentWithOverride() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await arInsertSetup(id: "setup_reopen_deadline", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_reopen_deadline",
                title: "Past Due",
                isOpen: false,
                dueAt: Date().addingTimeInterval(-60), on: app
            )
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/open",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let reopenedOptional = try await APIAssignment.find(assignment.id, on: app.db)
            #expect(reopenedOptional != nil)
            let reopened = try #require(reopenedOptional)
            #expect(reopened.isOpen)
            #expect(reopened.deadlineOverrideActive == true)

            _ = try await closeExpiredAssignments(on: app.db, logger: app.logger)
            let stillOpenOptional = try await APIAssignment.find(assignment.id, on: app.db)
            #expect(stillOpenOptional != nil)
            let stillOpen = try #require(stillOpenOptional)
            #expect(stillOpen.isOpen)

        }
    }

    // MARK: - GET /instructor

    @Test func studentCannotAccessAssignments() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func instructorCanAccessAssignments() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    // 500 expected because Leaf is not configured in tests — but middleware passed (not 401/403).
                    #expect(res.status != .unauthorized)
                    #expect(res.status != .forbidden)
                })

        }
    }

    @Test func assignmentsPageUsesDedicatedEnrollCSVPageLink() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("href=\"/instructor/enroll-csv\""))
                    #expect(html.contains("id=\"enroll-csv-file\"") == false)
                })

        }
    }

    @Test func assignmentsPageDefaultsEnrolledStudentsToMostRecentLastSeenFirst() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let now = Date()

            let never = try await arInsertStudent(username: "never_seen_student", displayName: "Never Seen", on: app)
            try await arEnrollStudentInTestCourse(never, on: app)

            let older = try await arInsertStudent(username: "older_seen_student", displayName: "Older Seen", on: app)
            older.lastSeenAt = now.addingTimeInterval(-3600)
            try await older.save(on: app.db)
            try await arEnrollStudentInTestCourse(older, on: app)

            let recent = try await arInsertStudent(username: "recent_seen_student", displayName: "Recent Seen", on: app)
            recent.lastSeenAt = now
            try await recent.save(on: app.db)
            try await arEnrollStudentInTestCourse(recent, on: app)

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("id=\"enrolled-students-table\""))
                    #expect(html.contains("var sortCol = 3;"))
                    #expect(html.contains("var sortAsc = false;"))
                    let recentIndex = try #require(html.range(of: "recent_seen_student")?.lowerBound)
                    let olderIndex = try #require(html.range(of: "older_seen_student")?.lowerBound)
                    let neverIndex = try #require(html.range(of: "never_seen_student")?.lowerBound)
                    XCTAssertLessThan(recentIndex, olderIndex)
                    XCTAssertLessThan(olderIndex, neverIndex)
                })

        }
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
    @Test func instructorDashboardBadgeCountsStudentsOnly() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            // Two real students, both enrolled.
            let s1 = try await arInsertStudent(username: "stat_s1", displayName: "Student One", on: app)
            try await arEnrollStudentInTestCourse(s1, on: app)
            let s2 = try await arInsertStudent(username: "stat_s2", displayName: "Student Two", on: app)
            try await arEnrollStudentInTestCourse(s2, on: app)

            // One extra instructor + one admin, also enrolled in the same
            // course.  These are the users whose submissions should NOT be
            // reflected in either side of the badge.
            let i1 = try await arInsertUser(
                username: "stat_i1", role: "instructor",
                displayName: "Helper Instructor", on: app)
            try await arEnrollStudentInTestCourse(i1, on: app)
            let a1 = try await arInsertUser(
                username: "stat_a1", role: "admin",
                displayName: "Helper Admin", on: app)
            try await arEnrollStudentInTestCourse(a1, on: app)

            // Setup + assignment.
            try await arInsertSetup(id: "setup_dashboard_filter", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_dashboard_filter",
                title: "Mixed-Role Assignment",
                isOpen: true, on: app
            )

            // One student-kind submission per user — same path the instructor
            // would hit when testing their own assignment via the submit form.
            try await arInsertSubmission(
                id: "sub_s1", testSetupID: "setup_dashboard_filter",
                userID: try s1.requireID(), on: app)
            try await arInsertSubmission(
                id: "sub_s2", testSetupID: "setup_dashboard_filter",
                userID: try s2.requireID(), on: app)
            try await arInsertSubmission(
                id: "sub_i1", testSetupID: "setup_dashboard_filter",
                userID: try i1.requireID(), on: app)
            try await arInsertSubmission(
                id: "sub_a1", testSetupID: "setup_dashboard_filter",
                userID: try a1.requireID(), on: app)

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string

                    // The leaf template renders the badge as
                    //   <span title="<X> / <Y> students submitted"><X> / <Y></span>
                    // We assert against the title (a unique, structural attribute)
                    // so the test doesn't depend on layout cosmetics.
                    let preMsg: Comment = """
                        Per-assignment badge should read '2 / 2 students submitted' \
                        (only enrolled students count); admin/instructor \
                        submissions and enrollments must be filtered out. \
                        Assignment publicID=\(assignment.publicID)
                        """
                    #expect(
                        html.contains("title=\"2 / 2 students submitted\""),
                        preMsg
                    )
                    let msg: Comment = """
                        Pre-v0.4.126 shape: admin/instructor inflated both X and Y. \
                        The fix in AssignmentRoutes.swift list() must scope both \
                        submittedStudentCount and enrolledStudentCount to \
                        enrolledStudentIDs.
                        """
                    #expect(html.contains("title=\"4 / 4 students submitted\"") == false, msg)
                })

        }
    }

    /// Dashboard card "Students With Browser Errors" counts distinct
    /// students who posted a client-side diagnostic (preflight or watchdog
    /// failure) on one of this course's test setups within the 24h window
    /// **and have no submission for that setup** (i.e. actually stuck).
    /// Diagnostics outside the window, on other courses' setups, with a null
    /// test_setup_id (stale), or from a student who later submitted (recovered)
    /// must not inflate the count.
    @Test func instructorDashboardCountsStudentsWithBrowserErrors() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let s1 = try await arInsertStudent(username: "browserErr_s1", on: app)
            try await arEnrollStudentInTestCourse(s1, on: app)
            let s2 = try await arInsertStudent(username: "browserErr_s2", on: app)
            try await arEnrollStudentInTestCourse(s2, on: app)
            let s3 = try await arInsertStudent(username: "browserErr_s3", on: app)
            try await arEnrollStudentInTestCourse(s3, on: app)

            try await arInsertSetup(id: "setup_browser_err", on: app)
            try await arInsertAssignment(
                testSetupID: "setup_browser_err",
                title: "Browser-error Metric Test",
                isOpen: true, on: app
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
            let staleStudent = try await arInsertStudent(username: "browserErr_stale", on: app)
            try await arEnrollStudentInTestCourse(staleStudent, on: app)
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

            // A student who hit a watchdog timeout but then reloaded and got a
            // submission in for that setup has self-recovered → must NOT count.
            let recovered = try await arInsertStudent(username: "browserErr_recovered", on: app)
            try await arEnrollStudentInTestCourse(recovered, on: app)
            let dRecovered = APIClientDiagnostic(
                userID: try recovered.requireID(),
                testSetupID: "setup_browser_err",
                kind: "watchdog_timeout",
                failedChecks: "kernel-unhealthy",
                userAgent: "TestUA"
            )
            try await dRecovered.save(on: app.db)
            _ = try await arInsertSubmission(
                id: "sub_browser_recovered",
                testSetupID: "setup_browser_err",
                userID: try recovered.requireID(),
                on: app
            )

            // Expected: 2 distinct stuck students (s1, s2).
            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string

                    let pattern = #"Students With Browser Errors</div>\s*<div class="diagnostic-value">(\d+)</div>"#
                    let re = try NSRegularExpression(pattern: pattern)
                    let nsr = NSRange(html.startIndex..., in: html)
                    guard let match = re.firstMatch(in: html, range: nsr),
                        let valueRange = Range(match.range(at: 1), in: html)
                    else {
                        Issue.record("Could not locate 'Students With Browser Errors' metric card in dashboard HTML")
                        return
                    }
                    let countMsg: Comment = """
                        Expected 2 stuck students (s1 + s2: recent diagnostics, \
                        no submission).  Out-of-window diagnostics, diagnostics \
                        with a null test_setup_id, and students who errored but \
                        later submitted (recovered) must not inflate the count.
                        """
                    #expect(String(html[valueRange]) == "2", countMsg)
                })

        }
    }
}
