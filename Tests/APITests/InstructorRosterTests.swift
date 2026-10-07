// Tests/APITests/InstructorRosterTests.swift
//
// The instructor Students and Slip days pages: the split between course staff
// and students, the polled fragment, the server-rendered LEARN flag, each
// student's own avatar, the filter threshold, and the slip-day pips, ordering
// and refund menu.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorRosterTests {

    private func enroll(
        _ username: String, role: CourseRole = .student, on app: Application
    ) async throws -> APIUser {
        let user = try await arInsertStudent(username: username, displayName: username, on: app)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role)
            .save(on: app.db)
        return user
    }

    // MARK: - Students

    @Test func staffAndStudentsAreSeparateLists() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await enroll("roster_ta", role: .ta, on: app)
            _ = try await enroll("roster_pupil", on: app)

            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            let staff = try #require(html.range(of: "id=\"course-staff-table\""))
            let students = try #require(html.range(of: "id=\"enrolled-students-table\""))
            let taName = try #require(html.range(of: "roster_ta"))
            let pupilName = try #require(html.range(of: "roster_pupil"))
            #expect(staff.lowerBound < taName.lowerBound && taName.lowerBound < students.lowerBound)
            #expect(students.lowerBound < pupilName.lowerBound)
        }
    }

    @Test func thePolledFragmentRendersStudentsOnly() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await enroll("frag_ta", role: .ta, on: app)
            _ = try await enroll("frag_pupil", on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APIPreEnrollment(courseID: courseID, username: "frag_pending").save(on: app.db)

            let html = try await getHTML(
                "/instructor/students-data?fragment=rows", cookie: cookie, on: app)
            #expect(html.contains("frag_pupil"))
            #expect(html.contains("frag_pending"))
            #expect(!html.contains("frag_ta"))
        }
    }

    @Test func learnFlagRendersFromTheStoredReadiness() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let flagged = try await enroll("learn_flagged", on: app)
            _ = try await enroll("learn_fine", on: app)
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == flagged.requireID()).first())
            enrollment.learnSyncReadiness = .unreachable
            // The sentence the sweep really stores, not a short stand-in.
            enrollment.brightspaceSyncDetail = LearnUnreachableReason.notOnClasslist.storedDetail
            try await enrollment.save(on: app.db)

            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            let row = try #require(html.range(of: "learn_flagged"))
            #expect(html[row.upperBound...].prefix(400).contains("class=\"tier tier-danger\""))
            #expect(html.components(separatedBy: "if confirmed dropped").count - 1 == 1)
            #expect(!html.contains("learn-check-btn"))
        }
    }

    @Test func learnFlagIsNilUnlessTheSweepSaidUnreachable() {
        let courseID = UUID()
        let enrollment = APICourseEnrollment(userID: UUID(), courseID: courseID, role: .student)
        #expect(InstructorDashboardRoutes.learnFlag(for: nil) == nil)
        #expect(InstructorDashboardRoutes.learnFlag(for: enrollment) == nil)
        enrollment.learnSyncReadiness = .confirmed
        #expect(InstructorDashboardRoutes.learnFlag(for: enrollment) == nil)
        enrollment.learnSyncReadiness = .unreachable
        // With no stored detail, the flag gives the advice that does no harm.
        #expect(InstructorDashboardRoutes.learnFlag(for: enrollment) == .noMatch)
        enrollment.brightspaceSyncDetail = LearnUnreachableReason.notOnClasslist.storedDetail
        #expect(InstructorDashboardRoutes.learnFlag(for: enrollment) == .notOnClasslist)
        enrollment.role = .ta
        #expect(InstructorDashboardRoutes.learnFlag(for: enrollment) == nil)
    }

    @Test func eachRowShowsTheStudentsOwnStoredAvatar() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await enroll("avatar_pupil", on: app)

            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            #expect(html.contains("class=\"avatar avatar-md\""))

            // The bird on the page is the stored one, the same the account page reads.
            let stored = try #require(
                try await APIUser.find(student.requireID(), on: app.db)?.avatarSpecJSON)
            let spec = try #require(AvatarStore.decode(stored))
            let presentation = AvatarPresentation(for: spec, size: .roster, accessibility: .decorative, isStaff: false)
            #expect(html.contains("--av-cap: var(\(presentation.capToken))"))
            #expect(html.contains("--av-backdrop: var(\(presentation.backdropToken))"))
        }
    }

    @Test func pendingRowHasNoAvatarAndSaysItIsAwaitingLogin() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APIPreEnrollment(courseID: courseID, username: "pending_pupil").save(on: app.db)

            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            let start = try #require(html.range(of: "js-student-row-pending"))
            let end = try #require(html.range(of: "</tr>", range: start.upperBound..<html.endIndex))
            let row = html[start.lowerBound..<end.upperBound]
            #expect(row.contains("pending_pupil"))
            #expect(row.contains("Awaiting first login"))
            #expect(row.contains("<span class=\"tier tier-preview\">Pending</span>"))
            #expect(!row.contains("class=\"avatar avatar-md\""))
        }
    }

    @Test func studentsFilterAppearsAtEightRows() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            for index in 0..<7 { _ = try await enroll("filter_\(index)", on: app) }
            #expect(!(try await getHTML("/instructor/students", cookie: cookie, on: app)).contains("filter-group"))
            _ = try await enroll("filter_7", on: app)
            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            #expect(html.contains("data-list-filter=\"enrolled-students-table\""))
        }
    }

    @Test func rowMenuOffersRemoveAndNoInlineTrashButton() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await enroll("menu_pupil", on: app)
            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            #expect(html.contains("aria-label=\"More actions for menu_pupil\""))
            #expect(html.contains("Remove from course"))
            #expect(!html.contains("students-unenroll-btn"))
        }
    }

    @Test func taSeesTheRosterReadOnly() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await enroll("ro_pupil", on: app)
            let cookie = try await loginUser(
                username: "ro_ta", password: "testpassword", role: "student", on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let ta = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "ro_ta").first())
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == ta.requireID()).filter(\.$course.$id == courseID).first())
            enrollment.role = .ta
            try await enrollment.save(on: app.db)

            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            #expect(html.contains("ro_pupil"))
            #expect(!html.contains("row-menu"))
            #expect(!html.contains("add-staff-panel"))
        }
    }

    // MARK: - Slip days

    @Test func pipsCoverTheWholeBudgetIncludingGrantedDays() {
        let pips = SlipDayPip.pips(total: 5, used: 2, extra: 2).map(\.state)
        #expect(pips == ["used", "used", "left", "extra", "extra"])
        #expect(SlipDayPip.pips(total: 3, used: 3, extra: 0).map(\.state) == ["used", "used", "used"])
        // A spent day that was a granted one is simply used.
        #expect(SlipDayPip.pips(total: 4, used: 4, extra: 1).map(\.state).allSatisfy { $0 == "used" })
        #expect(SlipDayPip.pips(total: 0, used: 0, extra: 0).isEmpty)
        // A claw-back can push used past total; the pips stop at total.
        #expect(SlipDayPip.pips(total: 2, used: 5, extra: 0).count == 2)
    }

    private func enableSlipDays(on app: Application, days: Int = 3) async throws -> APICourse {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        course.slipDaysEnabled = true
        course.slipDaysPerStudent = days
        course.slipDayExtensionHours = 24
        try await course.save(on: app.db)
        return course
    }

    @Test func ledgerIsOrderedMostUsedFirstThenByName() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await enableSlipDays(on: app)
            let courseID = try course.requireID()
            let alpha = try await enroll("sd_alpha", on: app)
            let zulu = try await enroll("sd_zulu", on: app)
            _ = try await enroll("sd_mike", on: app)
            try await arInsertSetup(id: "setup_sd_order", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_sd_order", title: "Order Lab", isOpen: false,
                dueAt: Date(timeIntervalSinceNow: -3600), on: app)
            _ = try await SlipDayStore.spend(
                userID: try zulu.requireID(), assignment: assignment,
                policy: course.slipDayPolicy, on: app.db)

            let rows = try await InstructorDashboardRoutes.loadSlipDayStudentRows(
                courseUUID: courseID, policy: course.slipDayPolicy, canManageLedger: true, db: app.db)
            #expect(rows.map(\.username) == ["sd_zulu", "sd_alpha", "sd_mike"])
            _ = alpha
            let totals = SlipDayTotals(rows: rows)
            #expect(totals.spent == 1)
            #expect(totals.budget == 9)
            #expect(totals.studentsWithSpends == 1)
        }
    }

    @Test func pipCountEqualsTheTotalWithAdjustments() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await enableSlipDays(on: app, days: 3)
            let courseID = try course.requireID()
            let student = try await enroll("sd_pips", on: app)
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == student.requireID()).first())
            enrollment.slipDaysAdjustment = 2
            try await enrollment.save(on: app.db)

            let rows = try await InstructorDashboardRoutes.loadSlipDayStudentRows(
                courseUUID: courseID, policy: course.slipDayPolicy, canManageLedger: true, db: app.db)
            let row = try #require(rows.first)
            #expect(row.pips.count == 5)
            #expect(row.pips.filter { $0.state == "extra" }.count == 2)
            #expect(row.adjustmentText == "+2 granted")
            #expect(row.leftText == "5 of 5 left")
        }
    }

    @Test func refundMenuAppearsOnlyForRefundableSpends() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await enableSlipDays(on: app)
            let spender = try await enroll("sd_spender", on: app)
            _ = try await enroll("sd_idle", on: app)
            try await arInsertSetup(id: "setup_sd_refund", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_sd_refund", title: "Refund Lab", isOpen: false,
                dueAt: Date(timeIntervalSinceNow: -3600), on: app)
            _ = try await SlipDayStore.spend(
                userID: try spender.requireID(), assignment: assignment,
                policy: course.slipDayPolicy, on: app.db)

            let html = try await getHTML("/instructor/slip-days", cookie: cookie, on: app)
            #expect(html.contains("Refund Refund Lab slip day"))
            #expect(html.contains("aria-label=\"More actions for sd_spender\""))
            #expect(!html.contains("aria-label=\"More actions for sd_idle\""))
            #expect(html.contains("Grant sd_idle one extra slip day"))
            #expect(html.contains("Remove one slip day from sd_idle"))
        }
    }

    @Test func factsCardStatesTheCourseNumbers() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await enableSlipDays(on: app, days: 3)
            _ = try await enroll("sd_facts", on: app)
            let hold = course.slipDayPolicy.releaseRevealHold

            let html = try await getHTML("/instructor/slip-days", cookie: cookie, on: app)
            #expect(html.contains("<dd><strong>3 days</strong></dd>"))
            #expect(html.contains("<strong>24 hours</strong>"))
            #expect(html.contains(hold ? "Held until claims lapse" : "Shown at each deadline"))
            #expect(html.contains("0 of 3 spent"))
            #expect(html.contains("class=\"tier tier-open\">On</span>"))
            #expect(html.contains("data-add-target=\"slip-settings-panel\""))
        }
    }
}
