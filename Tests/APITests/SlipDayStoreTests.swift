// Tests/APITests/SlipDayStoreTests.swift
//
// The slip-day ledger and its atomic spend/refund (#1228): balance math,
// the extension-row lifecycle (create on first spend, stack on the second,
// recompute/delete on refund), the staff-extension collision, the budget
// invariant under sequential and concurrent double-spends, and the ledger's
// appearance in the personal data export.  The pure offer-window rule
// (`slipDayOffer`) is pinned separately at the bottom.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class SlipDayStoreTests {

    let app: Application

    init() async throws {
        app = try await makeTestingApplication { app in
            try await configureTestDatabase(app)
        }
    }

    // MARK: - Helpers

    private let policy = SlipDayPolicy(enabled: true, daysPerStudent: 2, extensionHours: 24)

    private func makeCourse() async throws -> APICourse {
        let course = APICourse(code: "SLIP-\(UUID().uuidString.prefix(6))", name: "Slip Course")
        try await course.save(on: app.db)
        return course
    }

    @discardableResult
    private func makeEnrolledStudent(
        username: String, courseID: UUID, adjustment: Int? = nil
    ) async throws -> APIUser {
        let user = APIUser(username: username, passwordHash: "x", role: "student")
        try await user.save(on: app.db)
        let enrollment = APICourseEnrollment(
            userID: try user.requireID(), courseID: courseID, role: .student)
        enrollment.slipDaysAdjustment = adjustment
        try await enrollment.save(on: app.db)
        return user
    }

    private func makeAssignment(
        courseID: UUID, dueAt: Date? = Date(timeIntervalSinceNow: -3600)
    ) async throws -> APIAssignment {
        let setupID = UUID().uuidString
        let setup = APITestSetup(
            id: setupID, manifest: "{}", zipPath: "/tmp/\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Lab \(setupID.prefix(6))",
            dueAt: dueAt, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    private func extensionRow(
        assignmentID: UUID, userID: UUID
    ) async throws -> APIAssignmentExtension? {
        try await APIAssignmentExtension.query(on: app.db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()
    }

    // MARK: - Spend

    @Test func firstSpendWritesLedgerAndExtension() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_alice", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)
            let dueAt = try #require(assignment.dueAt)

            let receipt = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)

            #expect(receipt.spentOnAssignment == 1)
            #expect(receipt.remainingBalance == 1)
            #expect(abs(receipt.newDeadline.timeIntervalSince(dueAt) - 24 * 3600) < 1)

            let count = try await SlipDayStore.unrefundedCount(
                userID: userID, courseID: courseID, on: app.db)
            #expect(count == 1)

            let ext = try #require(
                try await extensionRow(
                    assignmentID: assignment.requireID(), userID: userID))
            #expect(abs(ext.extendedDueAt.timeIntervalSince(receipt.newDeadline)) < 1)
            #expect(ext.grantedByUserID == nil)
            #expect(ext.note == "Slip day (self-serve)")
        }
    }

    @Test func secondSpendStacksOnTheSameAssignment() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_bob", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)
            let dueAt = try #require(assignment.dueAt)

            _ = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)
            let second = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)

            #expect(second.spentOnAssignment == 2)
            #expect(second.remainingBalance == 0)
            #expect(abs(second.newDeadline.timeIntervalSince(dueAt) - 48 * 3600) < 1)

            // One extension row per (assignment, user), updated in place.
            let ext = try #require(
                try await extensionRow(
                    assignmentID: assignment.requireID(), userID: userID))
            #expect(abs(ext.extendedDueAt.timeIntervalSince(dueAt) - 48 * 3600) < 1)
            #expect(ext.note == "Slip days ×2 (self-serve)")

            let ledgerRows = try await APISlipDaySpend.query(on: app.db)
                .filter(\.$userID == userID)
                .count()
            #expect(ledgerRows == 2)
        }
    }

    @Test func spendBeyondBudgetThrowsAndRollsBack() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_carol", courseID: courseID)
            let userID = try student.requireID()
            let first = try await makeAssignment(courseID: courseID)
            let second = try await makeAssignment(courseID: courseID)
            let onePolicy = SlipDayPolicy(enabled: true, daysPerStudent: 1, extensionHours: 24)

            _ = try await SlipDayStore.spend(
                userID: userID, assignment: first, policy: onePolicy, on: app.db)

            await #expect(throws: SlipDayError.insufficientBalance) {
                _ = try await SlipDayStore.spend(
                    userID: userID, assignment: second, policy: onePolicy, on: self.app.db)
            }
            // The refused spend rolled back completely: no ledger row, no
            // extension row for the second assignment.
            let count = try await SlipDayStore.unrefundedCount(
                userID: userID, courseID: courseID, on: app.db)
            #expect(count == 1)
            let ext = try await extensionRow(
                assignmentID: second.requireID(), userID: userID)
            #expect(ext == nil)
        }
    }

    @Test func adjustmentRaisesTheBudget() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(
                username: "sd_dave", courseID: courseID, adjustment: 1)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)
            let onePolicy = SlipDayPolicy(enabled: true, daysPerStudent: 1, extensionHours: 24)

            _ = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: onePolicy, on: app.db)
            let second = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: onePolicy, on: app.db)
            #expect(second.remainingBalance == 0)

            await #expect(throws: SlipDayError.insufficientBalance) {
                _ = try await SlipDayStore.spend(
                    userID: userID, assignment: assignment, policy: onePolicy, on: self.app.db)
            }
        }
    }

    @Test func spendRefusedWhenStaffExtensionPresent() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_eve", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)

            // A staff-granted extension: an extension row the ledger did not
            // produce (the provenance rule keys off the missing spend rows,
            // not `grantedByUserID` — which carries an FK, hence nil here).
            let staffExt = APIAssignmentExtension(
                assignmentID: try assignment.requireID(), userID: userID,
                extendedDueAt: Date(timeIntervalSinceNow: 7 * 86400),
                note: "VIF accommodation", grantedByUserID: nil)
            try await staffExt.save(on: app.db)

            await #expect(throws: SlipDayError.staffExtensionPresent) {
                _ = try await SlipDayStore.spend(
                    userID: userID, assignment: assignment, policy: self.policy, on: self.app.db)
            }
            let count = try await SlipDayStore.unrefundedCount(
                userID: userID, courseID: courseID, on: app.db)
            #expect(count == 0)
            // The accommodation is untouched.
            let ext = try #require(
                try await extensionRow(
                    assignmentID: assignment.requireID(), userID: userID))
            #expect(ext.note == "VIF accommodation")
        }
    }

    @Test func spendRequiresEnrollmentAndDeadline() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let assignment = try await makeAssignment(courseID: courseID)

            // Not enrolled.
            let outsider = APIUser(username: "sd_outsider", passwordHash: "x", role: "student")
            try await outsider.save(on: app.db)
            await #expect(throws: SlipDayError.notEnrolled) {
                _ = try await SlipDayStore.spend(
                    userID: try outsider.requireID(), assignment: assignment,
                    policy: self.policy, on: self.app.db)
            }

            // No deadline.
            let student = try await makeEnrolledStudent(username: "sd_frank", courseID: courseID)
            let undated = try await makeAssignment(courseID: courseID, dueAt: nil)
            await #expect(throws: SlipDayError.assignmentHasNoDeadline) {
                _ = try await SlipDayStore.spend(
                    userID: try student.requireID(), assignment: undated,
                    policy: self.policy, on: self.app.db)
            }
        }
    }

    // MARK: - Refund

    @Test func refundRecomputesTheExtension() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_grace", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)
            let dueAt = try #require(assignment.dueAt)
            let staff = APIUser(username: "sd_staff1", passwordHash: "x", role: "user")
            try await staff.save(on: app.db)

            _ = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)
            let second = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)
            let secondID = try #require(
                try await APISlipDaySpend.query(on: app.db)
                    .filter(\.$userID == userID)
                    .filter(\.$refundedAt == nil)
                    .all()
                    .first { abs($0.extensionDueAt.timeIntervalSince(second.newDeadline)) < 1 }?
                    .id)

            let refunded = try await SlipDayStore.refund(
                spendID: secondID, courseID: courseID,
                refundedBy: staff.id, policy: policy, on: app.db)
            #expect(refunded.refundedAt != nil)
            #expect(refunded.refundedByUserID == staff.id)

            // Back to the one-day extension, and the day returned to the budget.
            let ext = try #require(
                try await extensionRow(
                    assignmentID: assignment.requireID(), userID: userID))
            #expect(abs(ext.extendedDueAt.timeIntervalSince(dueAt) - 24 * 3600) < 1)
            #expect(ext.note == "Slip day (self-serve)")
            let count = try await SlipDayStore.unrefundedCount(
                userID: userID, courseID: courseID, on: app.db)
            #expect(count == 1)
        }
    }

    @Test func refundToZeroDeletesTheExtension() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_henry", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)

            _ = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)
            let spendID = try #require(
                try await APISlipDaySpend.query(on: app.db)
                    .filter(\.$userID == userID).first()?.id)

            try await SlipDayStore.refund(
                spendID: spendID, courseID: courseID,
                refundedBy: nil, policy: policy, on: app.db)

            let ext = try await extensionRow(
                assignmentID: assignment.requireID(), userID: userID)
            #expect(ext == nil, "refund-to-zero must not leave the student the extension for free")
            let count = try await SlipDayStore.unrefundedCount(
                userID: userID, courseID: courseID, on: app.db)
            #expect(count == 0)
        }
    }

    @Test func refundIsSingleUseAndCourseScoped() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let otherCourse = try await makeCourse()
            let student = try await makeEnrolledStudent(username: "sd_iris", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)

            _ = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)
            let spendID = try #require(
                try await APISlipDaySpend.query(on: app.db)
                    .filter(\.$userID == userID).first()?.id)

            // Wrong course → not found (no cross-course refunds).
            await #expect(throws: SlipDayError.spendNotFound) {
                try await SlipDayStore.refund(
                    spendID: spendID, courseID: try otherCourse.requireID(),
                    refundedBy: nil, policy: self.policy, on: self.app.db)
            }

            try await SlipDayStore.refund(
                spendID: spendID, courseID: courseID,
                refundedBy: nil, policy: policy, on: app.db)
            await #expect(throws: SlipDayError.alreadyRefunded) {
                try await SlipDayStore.refund(
                    spendID: spendID, courseID: courseID,
                    refundedBy: nil, policy: self.policy, on: self.app.db)
            }
        }
    }

    // MARK: - Concurrency

    @Test func concurrentSpendsCannotExceedTheBudget() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_race", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)
            let onePolicy = SlipDayPolicy(enabled: true, daysPerStudent: 1, extensionHours: 24)

            // Two concurrent spends against a one-day balance — the
            // double-click case.  Whichever backend the suite runs on
            // (SQLite on api-tests, Postgres on api-tests-postgres), at most
            // one may commit; the loser throws (`insufficientBalance` on
            // Postgres, possibly a BUSY-class error on SQLite — both fail
            // closed).
            let db = app.db
            async let firstAttempt = Self.spendSucceeded(
                userID: userID, assignment: assignment, policy: onePolicy, db: db)
            async let secondAttempt = Self.spendSucceeded(
                userID: userID, assignment: assignment, policy: onePolicy, db: db)
            let successes = [await firstAttempt, await secondAttempt].filter { $0 }.count

            let committed = try await SlipDayStore.unrefundedCount(
                userID: userID, courseID: courseID, on: app.db)
            #expect(committed <= 1, "a one-day balance must never yield two committed spends")
            #expect(successes == committed, "every reported success must be a committed row")
        }
    }

    private static func spendSucceeded(
        userID: UUID, assignment: APIAssignment, policy: SlipDayPolicy, db: any Database
    ) async -> Bool {
        do {
            _ = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: db)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Data export

    @Test func spendsAppearInThePersonalDataExport() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse()
            let courseID = try course.requireID()
            let student = try await makeEnrolledStudent(username: "sd_export", courseID: courseID)
            let userID = try student.requireID()
            let assignment = try await makeAssignment(courseID: courseID)

            let receipt = try await SlipDayStore.spend(
                userID: userID, assignment: assignment, policy: policy, on: app.db)

            let content = try await gatherDataExportContent(for: student, on: app.db)
            let exported = try #require(content.gradingAdjustments.slipDaysSpent.first)
            #expect(exported.assignmentTitle == assignment.title)
            #expect(abs(exported.extendedDueAt.timeIntervalSince(receipt.newDeadline)) < 1)
            #expect(exported.refundedAt == nil)
        }
    }
}

// MARK: - Offer window (pure)

@Suite struct SlipDayOfferTests {

    private let policy = SlipDayPolicy(enabled: true, daysPerStudent: 2, extensionHours: 24)
    private let dueAt = Date(timeIntervalSince1970: 1_000_000)

    private func offer(
        policy: SlipDayPolicy? = nil,
        dueAt: Date?,
        balance: Int = 2,
        spentOnAssignment: Int = 0,
        hasForeignExtension: Bool = false,
        hoursAfterDeadline: Double
    ) -> SlipDayOffer? {
        slipDayOffer(
            policy: policy ?? self.policy,
            dueAt: dueAt,
            balance: balance,
            spentOnAssignment: spentOnAssignment,
            hasForeignExtension: hasForeignExtension,
            now: (dueAt ?? self.dueAt).addingTimeInterval(hoursAfterDeadline * 3600))
    }

    @Test func firstClaimInsideTheWindow() throws {
        let result = try #require(offer(dueAt: dueAt, hoursAfterDeadline: 1))
        #expect(result.isStacked == false)
        #expect(result.newDeadline == dueAt.addingTimeInterval(24 * 3600))
    }

    @Test func noOfferBeforeTheDeadline() {
        #expect(offer(dueAt: dueAt, hoursAfterDeadline: -1) == nil)
    }

    @Test func firstClaimWindowClosesAfterOneExtensionLength() {
        #expect(offer(dueAt: dueAt, hoursAfterDeadline: 25) == nil)
    }

    @Test func stackedClaimInsideTheHeldWindow() throws {
        let result = try #require(offer(dueAt: dueAt, spentOnAssignment: 1, hoursAfterDeadline: 23))
        #expect(result.isStacked == true)
        #expect(result.newDeadline == dueAt.addingTimeInterval(48 * 3600))
    }

    @Test func stackedClaimRefusedOnceTheHeldWindowLapses() {
        // dueAt + 48 h would still be in the future, but the currently-held
        // extension (dueAt + 24 h) has lapsed — banking a day for later is
        // exactly what the window rule forbids.
        #expect(offer(dueAt: dueAt, spentOnAssignment: 1, hoursAfterDeadline: 25) == nil)
    }

    @Test func disabledPolicyNilDeadlineForeignExtensionAndZeroBalanceAllRefuse() {
        let off = SlipDayPolicy(enabled: false, daysPerStudent: 2, extensionHours: 24)
        #expect(offer(policy: off, dueAt: dueAt, hoursAfterDeadline: 1) == nil)
        #expect(offer(dueAt: nil, hoursAfterDeadline: 1) == nil)
        #expect(offer(dueAt: dueAt, hasForeignExtension: true, hoursAfterDeadline: 1) == nil)
        #expect(offer(dueAt: dueAt, balance: 0, hoursAfterDeadline: 1) == nil)
    }

    @Test func hoursSettingScalesTheWindowAndTheExtension() {
        let chunky = SlipDayPolicy(enabled: true, daysPerStudent: 1, extensionHours: 48)
        let inside = offer(policy: chunky, dueAt: dueAt, hoursAfterDeadline: 47)
        #expect(inside?.newDeadline == dueAt.addingTimeInterval(48 * 3600))
        #expect(offer(policy: chunky, dueAt: dueAt, hoursAfterDeadline: 49) == nil)
    }
}
