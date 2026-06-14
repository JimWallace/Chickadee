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

            // Staff-only preview with a past open date → publishes to students.
            _ = try await arInsertSetup(id: "setup_open_preview", on: app)
            let preview = try await arInsertAssignment(
                testSetupID: "setup_open_preview", title: "Preview ready",
                isOpen: false,
                dueAt: Date().addingTimeInterval(86_400),
                startsAt: Date().addingTimeInterval(-60),
                validationStatus: "passed", on: app
            )
            preview.visibility = .preview
            try await preview.save(on: app.db)

            let openedCount = try await openScheduledAssignments(on: app.db, logger: app.logger)
            #expect(openedCount == 2)

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

            let previewReloaded = try #require(try await APIAssignment.find(preview.id, on: app.db))
            #expect(previewReloaded.visibility == .open, "Preview publishes to students at its open date")
            #expect(previewReloaded.startsAt == nil, "Open date is consumed once it fires")
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

    @Test func closeExpiredAssignmentsClosesAtDeadlineEvenWithActiveExtension() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await arInsertSetup(id: "setup_ext_close", on: app)
            let extended = try await arInsertAssignment(
                testSetupID: "setup_ext_close",
                title: "Extended overdue",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60), on: app
            )
            let extendedStudent = try await arInsertStudent(username: "extended_student", on: app)
            try await arEnrollStudentInTestCourse(extendedStudent, on: app)
            try await APIAssignmentExtension(
                assignmentID: try extended.requireID(),
                userID: try extendedStudent.requireID(),
                extendedDueAt: Date().addingTimeInterval(86_400)
            ).save(on: app.db)

            // A second overdue assignment with no extension also closes.
            _ = try await arInsertSetup(id: "setup_noext_close", on: app)
            let plain = try await arInsertAssignment(
                testSetupID: "setup_noext_close",
                title: "Plain overdue",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60), on: app
            )
            let regularStudent = try await arInsertStudent(username: "regular_student", on: app)
            try await arEnrollStudentInTestCourse(regularStudent, on: app)

            // Both assignments must auto-close at the deadline: an active
            // per-student extension does NOT hold the assignment-wide window
            // open (that's what made assignments appear never to close).
            let closedCount = try await closeExpiredAssignments(on: app.db, logger: app.logger)
            #expect(closedCount == 2, "Both expired assignments close, extension or not")

            let extendedReloaded = try #require(try await APIAssignment.find(extended.id, on: app.db))
            #expect(
                extendedReloaded.isOpen == false,
                "Assignment auto-closes at its deadline even with an active extension")
            let plainReloaded = try #require(try await APIAssignment.find(plain.id, on: app.db))
            #expect(plainReloaded.isOpen == false, "Assignment with no extension auto-closes")

            // After the close, per-student gating still grants the extended
            // student access (their effectiveDueAt is in the future) while the
            // non-extended student is held out.
            let extendedStillOpen = try await isAssignmentEffectivelyOpen(
                extendedReloaded, for: extendedStudent, on: app.db)
            #expect(extendedStillOpen, "Extended student can still submit after the auto-close")
            let regularBlocked = try await isAssignmentEffectivelyOpen(
                extendedReloaded, for: regularStudent, on: app.db)
            #expect(regularBlocked == false, "Non-extended student is blocked once the deadline passes")
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

            // The enrol-from-CSV link lives on the Students tab as of the
            // instructor-view rework (v0.4.283+).
            try await app.asyncTest(
                .GET, "/instructor/students",
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

            // The enrolled-students roster moved to the Students tab in the
            // instructor-view rework (v0.4.283+).
            try await app.asyncTest(
                .GET, "/instructor/students",
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

    /// Regression guard for the "Session refreshed" delete bug.  The three
    /// assignment delete forms in the Ungrouped table (the `closed` / `open` /
    /// preview-`#else` branches in assignments.leaf) were missing
    /// `#csrfFormField()`, so `POST /instructor/:id/delete` arrived with no
    /// `_csrf` token and the CSRF middleware 403'd it — rendering the
    /// "Session refreshed" error page instead of deleting.  With no course
    /// sections defined, every assignment renders in that Ungrouped table, so
    /// every delete failed.  This asserts each delete form embeds the hidden
    /// CSRF input across all three visibility states.
    @Test func deleteAssignmentFormsIncludeCSRFTokenInUngroupedTable() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            // One assignment in each visibility state that drives a distinct
            // template branch: open, closed, and preview (the `#else`).
            try await arInsertSetup(id: "setup_del_open", on: app)
            let openA = try await arInsertAssignment(
                testSetupID: "setup_del_open", title: "Open One",
                isOpen: true, validationStatus: "passed", on: app)

            try await arInsertSetup(id: "setup_del_closed", on: app)
            let closedA = try await arInsertAssignment(
                testSetupID: "setup_del_closed", title: "Closed One",
                isOpen: false, validationStatus: "passed", on: app)

            try await arInsertSetup(id: "setup_del_preview", on: app)
            let previewA = try await arInsertAssignment(
                testSetupID: "setup_del_preview", title: "Preview One",
                isOpen: false, validationStatus: "passed", on: app)
            previewA.visibility = .preview
            try await previewA.save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    for assignment in [openA, closedA, previewA] {
                        let action = "action=\"/instructor/\(assignment.publicID)/delete\""
                        let actionRange = try #require(
                            html.range(of: action),
                            "Expected a delete form for assignment \(assignment.publicID)"
                        )
                        let formEnd = try #require(
                            html.range(of: "</form>", range: actionRange.upperBound..<html.endIndex),
                            "Delete form for \(assignment.publicID) is not closed"
                        )
                        let formSegment = html[actionRange.upperBound..<formEnd.lowerBound]
                        #expect(
                            formSegment.contains("name='_csrf'"),
                            "Delete form for \(assignment.publicID) must include the CSRF hidden field"
                        )
                    }
                })

        }
    }

}
