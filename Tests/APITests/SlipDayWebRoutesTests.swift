// Tests/APITests/SlipDayWebRoutesTests.swift
//
// The student slip-day flow, end to end over the web surface (#1228):
//
//   - the dashboard shows the balance line and the calendar action only when
//     the full offer condition holds (enabled ∧ deadline passed ∧ inside the
//     claim window ∧ balance ∧ no staff extension ∧ non-staff viewer)
//   - GET /testsetups/:id/slip-day renders the explicit confirmation page
//     when the offer holds, and redirects home when it does not
//   - POST spends exactly one day (ledger row + extension row + audit),
//     stacks on a second POST, and refuses without writing outside the
//     window, over budget, for staff, or against a staff extension
//   - a spend actually reopens submission for the student
//   - the balance shows on /account

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct SlipDayWebRoutesTests {

    /// Seeds the CS101 course with slip days enabled, one auto-closed
    /// assignment whose deadline passed `dueAgo` seconds ago, and the
    /// logged-in student1, returning the session cookie and the rows.
    @discardableResult
    private func seedSlipDayFixture(
        app: Application,
        setupID: String,
        dueAgo: TimeInterval = 3600,
        enabled: Bool = true,
        days: Int = 2,
        hours: Int = 24
    ) async throws -> (cookie: String, student: APIUser, assignment: APIAssignment) {
        let cookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        let course = try await wrMakeCourse(on: app)
        course.slipDaysEnabled = enabled
        course.slipDaysPerStudent = days
        course.slipDayExtensionHours = hours
        try await course.save(on: app.db)
        try await wrInsertSetup(id: setupID, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Slip Lab", isOpen: false,
            dueAt: Date(timeIntervalSinceNow: -dueAgo), on: app)
        return (cookie, student, assignment)
    }

    private func pageHTML(
        app: Application, path: String, cookie: String
    ) async throws -> (status: HTTPStatus, html: String) {
        var status = HTTPStatus.imATeapot
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                status = res.status
                html = res.body.string
            })
        return (status, html)
    }

    private func slipDayPOST(
        app: Application, setupID: String, cookie: String
    ) async throws -> HTTPStatus {
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        var status = HTTPStatus.imATeapot
        try await app.asyncTest(
            .POST, "/testsetups/\(setupID)/slip-day",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
            })
        return status
    }

    private func ledgerCount(app: Application, userID: UUID) async throws -> Int {
        try await APISlipDaySpend.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$refundedAt == nil)
            .count()
    }

    // MARK: - Dashboard offer surface

    @Test func dashboardShowsBalanceAndCalendarActionWhenEligible() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedSlipDayFixture(app: app, setupID: "setup_sd1")
            let (status, html) = try await pageHTML(app: app, path: "/", cookie: cookie)
            #expect(status == .ok)
            #expect(html.contains("2 of 2 slip days"))
            #expect(html.contains("/testsetups/setup_sd1/slip-day"))
            #expect(html.contains("Use a slip day"))
        }
    }

    @Test func dashboardHidesSlipDaySurfaceWhenPolicyOff() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd2", enabled: false)
            let (status, html) = try await pageHTML(app: app, path: "/", cookie: cookie)
            #expect(status == .ok)
            #expect(!html.contains("Slip days:"))
            #expect(!html.contains("/testsetups/setup_sd2/slip-day"))
        }
    }

    @Test func dashboardHidesActionWhenStaffExtensionExists() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd3")
            // Foreign-extension provenance keys off the missing spend rows,
            // not `grantedByUserID` (which carries an FK, hence nil here).
            let staffExt = APIAssignmentExtension(
                assignmentID: try assignment.requireID(),
                userID: try student.requireID(),
                extendedDueAt: Date(timeIntervalSinceNow: 7 * 86400),
                note: "accommodation", grantedByUserID: nil)
            try await staffExt.save(on: app.db)

            let (status, html) = try await pageHTML(app: app, path: "/", cookie: cookie)
            #expect(status == .ok)
            // The balance line stays (they still hold their budget); the
            // action on this row goes.
            #expect(!html.contains("/testsetups/setup_sd3/slip-day"))
        }
    }

    // MARK: - Confirmation page

    @Test func confirmPageRendersTheOffer() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedSlipDayFixture(app: app, setupID: "setup_sd4")
            let (status, html) = try await pageHTML(
                app: app, path: "/testsetups/setup_sd4/slip-day", cookie: cookie)
            #expect(status == .ok)
            #expect(html.contains("Slip Lab"))
            #expect(html.contains("1 of your"))
            #expect(html.contains("Use a slip day"))
            #expect(html.contains("cannot be returned by you"))
        }
    }

    @Test func confirmPageRedirectsWhenDeadlineNotPassed() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd5", dueAgo: -3600)
            let (status, _) = try await pageHTML(
                app: app, path: "/testsetups/setup_sd5/slip-day", cookie: cookie)
            #expect(status == .seeOther)
        }
    }

    // MARK: - The spend POST

    @Test func spendWritesLedgerExtensionAndAudit() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd6")
            let userID = try student.requireID()
            let dueAt = try #require(assignment.dueAt)

            let status = try await slipDayPOST(app: app, setupID: "setup_sd6", cookie: cookie)
            #expect(status == .seeOther)

            #expect(try await ledgerCount(app: app, userID: userID) == 1)
            let ext = try #require(
                try await APIAssignmentExtension.query(on: app.db)
                    .filter(\.$assignmentID == assignment.requireID())
                    .filter(\.$userID == userID)
                    .first())
            #expect(abs(ext.extendedDueAt.timeIntervalSince(dueAt) - 24 * 3600) < 1)

            let auditCount = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.slipDaySpent.rawValue)
                .count()
            #expect(auditCount == 1)

            // The spend reopens submission for this student.
            let fresh = try #require(
                try await APIAssignment.find(assignment.requireID(), on: app.db))
            let open = try await isAssignmentEffectivelyOpen(fresh, for: student, on: app.db)
            #expect(open)

            // The dashboard reflects the spend: one day left, the row now
            // "extended", and the stacked relabel on the action.
            let (_, html) = try await pageHTML(app: app, path: "/", cookie: cookie)
            #expect(html.contains("1 of 2 slip days"))
            #expect(html.contains("Use another slip day"))

            // The balance shows on /account too.
            let (_, accountHTML) = try await pageHTML(app: app, path: "/account", cookie: cookie)
            #expect(accountHTML.contains("1 of 2 slip days left"))
        }
    }

    @Test func secondSpendStacksAndThirdIsRefused() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd7")
            let userID = try student.requireID()
            let dueAt = try #require(assignment.dueAt)

            #expect(try await slipDayPOST(app: app, setupID: "setup_sd7", cookie: cookie) == .seeOther)
            #expect(try await slipDayPOST(app: app, setupID: "setup_sd7", cookie: cookie) == .seeOther)
            #expect(try await ledgerCount(app: app, userID: userID) == 2)
            let ext = try #require(
                try await APIAssignmentExtension.query(on: app.db)
                    .filter(\.$assignmentID == assignment.requireID())
                    .filter(\.$userID == userID)
                    .first())
            #expect(abs(ext.extendedDueAt.timeIntervalSince(dueAt) - 48 * 3600) < 1)

            // Balance exhausted: the third POST refuses without writing.
            #expect(try await slipDayPOST(app: app, setupID: "setup_sd7", cookie: cookie) == .seeOther)
            #expect(try await ledgerCount(app: app, userID: userID) == 2)
        }
    }

    @Test func spendRefusedOutsideTheClaimWindow() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, _) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd8", dueAgo: 25 * 3600)
            let status = try await slipDayPOST(app: app, setupID: "setup_sd8", cookie: cookie)
            #expect(status == .seeOther)
            #expect(try await ledgerCount(app: app, userID: student.requireID()) == 0)
        }
    }

    @Test func spendRefusedForStaff() async throws {
        try await withWebRoutesApp { app in
            _ = try await seedSlipDayFixture(app: app, setupID: "setup_sd9")
            let staffCookie = try await wrLoginAsInstructor(on: app)
            let staff = try #require(
                try await APIUser.query(on: app.db)
                    .filter(\.$username == "instructor1").first())
            try await wrEnrollUser(staff, on: app)

            let status = try await slipDayPOST(
                app: app, setupID: "setup_sd9", cookie: staffCookie)
            #expect(status == .seeOther)
            #expect(try await ledgerCount(app: app, userID: staff.requireID()) == 0)
        }
    }

    @Test func spendRefusedWhenStaffExtensionExists() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedSlipDayFixture(
                app: app, setupID: "setup_sd10")
            let userID = try student.requireID()
            let staffExt = APIAssignmentExtension(
                assignmentID: try assignment.requireID(), userID: userID,
                extendedDueAt: Date(timeIntervalSinceNow: 7 * 86400),
                note: "accommodation", grantedByUserID: nil)
            try await staffExt.save(on: app.db)

            let status = try await slipDayPOST(app: app, setupID: "setup_sd10", cookie: cookie)
            #expect(status == .seeOther)
            #expect(try await ledgerCount(app: app, userID: userID) == 0)
        }
    }
}
