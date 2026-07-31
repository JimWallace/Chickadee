// Tests/APITests/InstructorSlipDaysPanelTests.swift
//
// The instructor Slip days tab (#1228): staff-only visibility, the policy
// form's instructor floor (TA read-only + save refusal), the settings save
// round-trip, per-student budget adjustments at the TA floor, and the refund
// path recomputing the extension — with the audit trail for each.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorSlipDaysPanelTests {

    /// Logs in a per-course TA in the shared TEST101 course: a plain user
    /// whose only staff standing is the `.ta` enrollment (upserted, since
    /// the `.auto` course auto-enrolls them as `.student` at login).
    private func loginAsTA(on app: Application) async throws -> String {
        let cookie = try await loginUser(
            username: "testta", password: "testpassword", role: "student", on: app)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "testta").first())
        let userID = try user.requireID()
        if let existing = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID).filter(\.$course.$id == courseID).first()
        {
            existing.role = .ta
            try await existing.save(on: app.db)
        } else {
            try await APICourseEnrollment(userID: userID, courseID: courseID, role: .ta)
                .save(on: app.db)
        }
        return cookie
    }

    /// Enrolls a fresh student-role user in TEST101 and returns them.
    private func seedEnrolledStudent(
        username: String, on app: Application
    ) async throws -> APIUser {
        let student = try await arInsertStudent(username: username, on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        return student
    }

    /// Enables the slip-day policy on TEST101 and returns the course.
    @discardableResult
    private func enableSlipDays(
        on app: Application, days: Int = 2, hours: Int = 24
    ) async throws -> APICourse {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        course.slipDaysEnabled = true
        course.slipDaysPerStudent = days
        course.slipDayExtensionHours = hours
        try await course.save(on: app.db)
        return course
    }

    private func panelPOST(
        app: Application, path: String, fields: [String: String], cookie: String
    ) async throws -> HTTPStatus {
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/slip-days", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = csrf
        var status = HTTPStatus.imATeapot
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
            })
        return status
    }

    // MARK: - Access + rendering

    @Test func studentCannotAccessSlipDaysTab() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, "/instructor/slip-days",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .forbidden) })
        }
    }

    @Test func instructorSeesSettingsAndRosterLedger() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await seedEnrolledStudent(username: "sdp_student1", on: app)
            try await app.asyncTest(
                .GET, "/instructor/slip-days",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Enable slip days for TEST101"))
                    #expect(html.contains("Roster ledger"))
                    #expect(html.contains("sdp_student1"))
                    #expect(html.contains(">Save settings<"))
                })
        }
    }

    @Test func taSeesReadOnlySettings() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsTA(on: app)
            try await app.asyncTest(
                .GET, "/instructor/slip-days",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("instructors can change slip-day policy"))
                    #expect(!html.contains(">Save settings<"))
                })
        }
    }

    // MARK: - Settings

    @Test func instructorSavesSettings() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let status = try await panelPOST(
                app: app, path: "/instructor/slip-days/settings",
                fields: ["enabled": "on", "daysPerStudent": "3", "extensionHours": "48"],
                cookie: cookie)
            #expect(status == .seeOther)

            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            let policy = course.slipDayPolicy
            #expect(policy.enabled)
            #expect(policy.daysPerStudent == 3)
            #expect(policy.extensionHours == 48)

            let auditCount = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.slipDaySettingsChanged.rawValue)
                .count()
            #expect(auditCount == 1)
        }
    }

    @Test func taCannotSaveSettings() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsTA(on: app)
            let status = try await panelPOST(
                app: app, path: "/instructor/slip-days/settings",
                fields: ["enabled": "on", "daysPerStudent": "3", "extensionHours": "48"],
                cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func outOfRangeValuesAreRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let status = try await panelPOST(
                app: app, path: "/instructor/slip-days/settings",
                fields: ["enabled": "on", "daysPerStudent": "101", "extensionHours": "24"],
                cookie: cookie)
            #expect(status == .seeOther)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            #expect(course.slipDaysEnabled != true, "refused save must not enable the policy")
        }
    }

    // MARK: - Adjustments

    @Test func taAdjustsAStudentBudget() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsTA(on: app)
            let student = try await seedEnrolledStudent(username: "sdp_adjust", on: app)
            let studentID = try student.requireID()

            let status = try await panelPOST(
                app: app, path: "/instructor/slip-days/adjust",
                fields: ["userID": studentID.uuidString, "delta": "1"],
                cookie: cookie)
            #expect(status == .seeOther)

            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == studentID)
                    .filter(\.$course.$id == courseID)
                    .first())
            #expect(enrollment.slipDaysAdjustment == 1)

            // The audit row names the student for the data-export subject match.
            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.slipDayAdjustmentChanged.rawValue)
                    .first())
            #expect(entry.metadata?.contains("sdp_adjust") == true)
        }
    }

    @Test func adjustRefusesNonStudentTargets() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db)
                    .filter(\.$username == "testinstructor").first())
            let status = try await panelPOST(
                app: app, path: "/instructor/slip-days/adjust",
                fields: ["userID": try instructor.requireID().uuidString, "delta": "1"],
                cookie: cookie)
            #expect(status == .seeOther)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == instructor.requireID())
                    .filter(\.$course.$id == courseID)
                    .first())
            #expect(enrollment.slipDaysAdjustment == nil)
        }
    }

    // MARK: - Refunds

    @Test func refundRecomputesExtensionAndRestoresBalance() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await enableSlipDays(on: app)
            let courseID = try course.requireID()
            let student = try await seedEnrolledStudent(username: "sdp_refund", on: app)
            let studentID = try student.requireID()

            try await arInsertSetup(id: "setup_sdp1", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_sdp1", title: "Refund Lab", isOpen: false,
                dueAt: Date(timeIntervalSinceNow: -3600), on: app)

            // The student spent one day (store-level; the web path is covered
            // in SlipDayWebRoutesTests).
            _ = try await SlipDayStore.spend(
                userID: studentID, assignment: assignment,
                policy: course.slipDayPolicy, on: app.db)
            let spendID = try #require(
                try await APISlipDaySpend.query(on: app.db)
                    .filter(\.$userID == studentID).first()?.id)

            let status = try await panelPOST(
                app: app, path: "/instructor/slip-days/refund",
                fields: ["spendID": spendID.uuidString],
                cookie: cookie)
            #expect(status == .seeOther)

            let refunded = try #require(try await APISlipDaySpend.find(spendID, on: app.db))
            #expect(refunded.refundedAt != nil)
            // Sole spend refunded → the extension row is gone and the balance
            // restored.
            let ext = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$assignmentID == assignment.requireID())
                .filter(\.$userID == studentID)
                .first()
            #expect(ext == nil)
            let count = try await SlipDayStore.unrefundedCount(
                userID: studentID, courseID: courseID, on: app.db)
            #expect(count == 0)

            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.slipDayRefunded.rawValue)
                    .first())
            #expect(entry.metadata?.contains("sdp_refund") == true)

            // The refunded spend stays visible in the ledger, struck through.
            try await app.asyncTest(
                .GET, "/instructor/slip-days",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("refunded"))
                })
        }
    }

    @Test func refundingTwiceIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await enableSlipDays(on: app)
            let student = try await seedEnrolledStudent(username: "sdp_double", on: app)

            try await arInsertSetup(id: "setup_sdp2", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_sdp2", title: "Double Lab", isOpen: false,
                dueAt: Date(timeIntervalSinceNow: -3600), on: app)
            _ = try await SlipDayStore.spend(
                userID: try student.requireID(), assignment: assignment,
                policy: course.slipDayPolicy, on: app.db)
            let spendID = try #require(
                try await APISlipDaySpend.query(on: app.db)
                    .filter(\.$userID == student.requireID()).first()?.id)

            let first = try await panelPOST(
                app: app, path: "/instructor/slip-days/refund",
                fields: ["spendID": spendID.uuidString], cookie: cookie)
            #expect(first == .seeOther)
            let second = try await panelPOST(
                app: app, path: "/instructor/slip-days/refund",
                fields: ["spendID": spendID.uuidString], cookie: cookie)
            // Refused via the flash redirect; only one refund audit row.
            #expect(second == .seeOther)
            let auditCount = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.slipDayRefunded.rawValue)
                .count()
            #expect(auditCount == 1)
        }
    }
}
