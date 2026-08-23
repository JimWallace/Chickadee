// Tests/APITests/SolutionVisibilityGateTests.swift
//
// The solution-reveal gate and the slip-day claim-window ceiling it stands on:
//
//   - `slipDayClaimWindowCeiling` (pure): the window end while a claim is
//     still reachable, nil once it cannot be (policy off, no deadline, no
//     balance, staff extension, window lapsed)
//   - `solutionVisibleToStudent` (DB): policy + published-state + override +
//     per-student reveal deadline, including the case the ceiling exists for —
//     a student who could still buy time with a slip day
//   - `releaseVisibilityDeadline`: pushed out to the claim-window end in a
//     slip-day course, so release output can no longer be read at due+1min
//     and then acted on with a freshly claimed slip day

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct SolutionVisibilityGateTests {

    private let slipPolicy = SlipDayPolicy(enabled: true, daysPerStudent: 2, extensionHours: 24)
    private let noSlip = SlipDayPolicy(enabled: false, daysPerStudent: 2, extensionHours: 24)

    // MARK: - slipDayClaimWindowCeiling (pure)

    @Test func ceilingIsNilWhenPolicyDisabled() {
        let due = Date(timeIntervalSinceNow: -3600)
        #expect(
            slipDayClaimWindowCeiling(
                policy: noSlip, dueAt: due, balance: 2, spentOnAssignment: 0,
                hasForeignExtension: false) == nil)
    }

    @Test func ceilingIsNilWithoutDeadlineBalanceOrAgainstStaffExtension() {
        let due = Date(timeIntervalSinceNow: -3600)
        #expect(
            slipDayClaimWindowCeiling(
                policy: slipPolicy, dueAt: nil, balance: 2, spentOnAssignment: 0,
                hasForeignExtension: false) == nil)
        #expect(
            slipDayClaimWindowCeiling(
                policy: slipPolicy, dueAt: due, balance: 0, spentOnAssignment: 0,
                hasForeignExtension: false) == nil)
        #expect(
            slipDayClaimWindowCeiling(
                policy: slipPolicy, dueAt: due, balance: 2, spentOnAssignment: 0,
                hasForeignExtension: true) == nil)
    }

    @Test func ceilingIsFirstClaimWindowEndInsideTheWindow() {
        let due = Date(timeIntervalSinceNow: -3600)
        let ceiling = slipDayClaimWindowCeiling(
            policy: slipPolicy, dueAt: due, balance: 2, spentOnAssignment: 0,
            hasForeignExtension: false)
        #expect(ceiling == due.addingTimeInterval(24 * 3600))
    }

    @Test func ceilingFollowsStackedSpends() {
        let due = Date(timeIntervalSinceNow: -30 * 3600)
        // Two spends hold a window to due+48h; 30h past due is inside it.
        let ceiling = slipDayClaimWindowCeiling(
            policy: slipPolicy, dueAt: due, balance: 1, spentOnAssignment: 2,
            hasForeignExtension: false)
        #expect(ceiling == due.addingTimeInterval(48 * 3600))
    }

    @Test func ceilingIsNilOnceTheWindowLapses() {
        let due = Date(timeIntervalSinceNow: -25 * 3600)
        #expect(
            slipDayClaimWindowCeiling(
                policy: slipPolicy, dueAt: due, balance: 2, spentOnAssignment: 0,
                hasForeignExtension: false) == nil)
    }

    @Test func ceilingStandsBeforeTheDeadlineToo() {
        // Callers compare the date against `now` themselves, so the window
        // end is returned on both sides of the deadline — stability across
        // the boundary is what keeps max(effective, ceiling) monotone.
        let due = Date(timeIntervalSinceNow: 3600)
        let ceiling = slipDayClaimWindowCeiling(
            policy: slipPolicy, dueAt: due, balance: 1, spentOnAssignment: 0,
            hasForeignExtension: false)
        #expect(ceiling == due.addingTimeInterval(24 * 3600))
    }

    // MARK: - solutionVisibleToStudent (DB-backed)

    /// Seeds student1 (enrolled), the CS101 course with the given slip-day
    /// policy, and one assignment carrying the reveal policy, returning the
    /// pieces the predicate needs.
    private func seedGateFixture(
        app: Application,
        setupID: String,
        dueAt: Date?,
        isOpen: Bool = false,
        solutionVisibility: SolutionVisibility = .afterDue,
        slipDaysEnabled: Bool = false,
        releaseRevealHold: Bool = true
    ) async throws -> (student: APIUser, assignment: APIAssignment) {
        _ = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        let course = try await wrMakeCourse(on: app)
        course.slipDaysEnabled = slipDaysEnabled
        course.slipDaysPerStudent = 2
        course.slipDayExtensionHours = 24
        course.slipDayReleaseRevealHold = releaseRevealHold
        try await course.save(on: app.db)
        try await wrInsertSetup(id: setupID, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Reveal Lab", isOpen: isOpen, dueAt: dueAt, on: app)
        assignment.solutionVisibility = solutionVisibility
        try await assignment.save(on: app.db)
        return (student, assignment)
    }

    @Test func hiddenPolicyIsNeverVisible() async throws {
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv1",
                dueAt: Date(timeIntervalSinceNow: -25 * 3600),
                solutionVisibility: .hidden)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }

    @Test func visibleAfterDueWhenSlipDaysAreOff() async throws {
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv2", dueAt: Date(timeIntervalSinceNow: -3600))
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db))
        }
    }

    @Test func hiddenBeforeTheDeadline() async throws {
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv3", dueAt: Date(timeIntervalSinceNow: 3600),
                isOpen: true)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }

    @Test func hiddenWhileASlipDayClaimIsStillReachable() async throws {
        try await withWebRoutesApp { app in
            // One hour past due, slip days on, full balance: the student could
            // still claim a day and submit — the answer key must wait.
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv4", dueAt: Date(timeIntervalSinceNow: -3600),
                slipDaysEnabled: true)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }

    @Test func visibleOnceTheSlipClaimWindowLapses() async throws {
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv5", dueAt: Date(timeIntervalSinceNow: -25 * 3600),
                slipDaysEnabled: true)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db))
        }
    }

    @Test func hiddenWhileAStaffExtensionIsLive() async throws {
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv6", dueAt: Date(timeIntervalSinceNow: -25 * 3600))
            let ext = APIAssignmentExtension(
                assignmentID: try assignment.requireID(),
                userID: try student.requireID(),
                extendedDueAt: Date(timeIntervalSinceNow: 7 * 86400),
                note: "accommodation", grantedByUserID: nil)
            try await ext.save(on: app.db)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }

    @Test func visibleImmediatelyOnAnOpenAssignmentWithNoDeadline() async throws {
        // The posted-lecture-material case: open, no due date, policy on.
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv7", dueAt: nil, isOpen: true)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db))
        }
    }

    @Test func neverVisibleOnAnUnpublishedDraft() async throws {
        // Closed with no past due date is a draft: not student-visible by
        // state, so the policy must not leak the solution pre-publication.
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv8", dueAt: nil, isOpen: false)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }

    @Test func suppressedWhileADeadlineOverrideIsActive() async throws {
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv9", dueAt: Date(timeIntervalSinceNow: -25 * 3600),
                isOpen: true)
            assignment.deadlineOverrideActive = true
            try await assignment.save(on: app.db)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }

    // MARK: - releaseVisibilityDeadline (the pre-existing reveal gate)

    @Test func releaseDeadlineIsPushedToTheClaimWindowEnd() async throws {
        try await withWebRoutesApp { app in
            let due = Date(timeIntervalSinceNow: -3600)
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv10", dueAt: due, slipDaysEnabled: true)
            let deadline = try await releaseVisibilityDeadline(
                for: assignment, user: student, on: app.db)
            // Inside the claim window the reveal waits for its end, so release
            // output cannot be read at due+1min and acted on with a fresh
            // slip-day claim.
            #expect(deadline == due.addingTimeInterval(24 * 3600))
        }
    }

    @Test func releaseDeadlineStaysTheDueDateWithoutSlipDays() async throws {
        try await withWebRoutesApp { app in
            let due = Date(timeIntervalSinceNow: -3600)
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv11", dueAt: due)
            let deadline = try await releaseVisibilityDeadline(
                for: assignment, user: student, on: app.db)
            #expect(deadline == due)
        }
    }

    @Test func releaseDeadlineHonoursTheCourseOptOut() async throws {
        // A course that switched the reveal hold off gets the pre-hold
        // timing back: release output at the effective deadline, even inside
        // a still-claimable window — the instructor's stated choice.
        try await withWebRoutesApp { app in
            let due = Date(timeIntervalSinceNow: -3600)
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv12", dueAt: due,
                slipDaysEnabled: true, releaseRevealHold: false)
            let deadline = try await releaseVisibilityDeadline(
                for: assignment, user: student, on: app.db)
            #expect(deadline == due)
        }
    }

    @Test func solutionGateIgnoresTheReleaseOptOut() async throws {
        // The opt-out relaxes release output only. The answer key must never
        // be readable while a slip-day claim is still on the table, whatever
        // the course chose for release timing.
        try await withWebRoutesApp { app in
            let (student, assignment) = try await seedGateFixture(
                app: app, setupID: "setup_sv13", dueAt: Date(timeIntervalSinceNow: -3600),
                slipDaysEnabled: true, releaseRevealHold: false)
            #expect(
                try await solutionVisibleToStudent(
                    assignment: assignment, user: student, on: app.db) == false)
        }
    }
}
