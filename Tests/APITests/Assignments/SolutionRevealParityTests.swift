// Tests/APITests/Assignments/SolutionRevealParityTests.swift
//
// The solution reveal has one rule and two callers (#2665): the serving
// routes resolve it from the database (`solutionVisibleToStudent(assignment:
// user:on:)`), and the dashboard resolves it from its batch-loaded rows
// (`DashboardSlipDayData.claimState` and the pure `solutionVisibleToStudent`).
// Each case below runs through both, and the two must agree with each other
// and with the expected answer. A dashboard that offers a Solution link the
// notebook route refuses is the failure this guards.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct SolutionRevealParityTests {

    struct RevealCase: Sendable, CustomTestStringConvertible {
        let label: String
        /// Hours from now to the due date; nil is no deadline.
        let dueInHours: Double?
        var isOpen = false
        var policy: SolutionVisibility = .afterDue
        var slipDaysEnabled = false
        /// Slip days the student has already spent on this assignment.
        var spends = 0
        /// Hours from now to a staff-granted extension; nil is none.
        var staffExtensionInHours: Double?
        var overrideActive = false
        let expected: Bool

        var testDescription: String { label }
    }

    static let cases: [RevealCase] = [
        RevealCase(label: "policy hidden", dueInHours: -25, policy: .hidden, expected: false),
        RevealCase(label: "past due, slip days off", dueInHours: -1, expected: true),
        RevealCase(label: "before the deadline", dueInHours: 1, isOpen: true, expected: false),
        RevealCase(
            label: "slip claim still reachable", dueInHours: -1, slipDaysEnabled: true,
            expected: false),
        RevealCase(
            label: "slip claim window lapsed", dueInHours: -25, slipDaysEnabled: true,
            expected: true),
        RevealCase(
            label: "inside a spent slip day", dueInHours: -1, slipDaysEnabled: true, spends: 1,
            expected: false),
        RevealCase(
            label: "spent slip day over, window held", dueInHours: -30, slipDaysEnabled: true,
            spends: 1, expected: true),
        RevealCase(
            label: "staff extension live", dueInHours: -25, staffExtensionInHours: 7 * 24,
            expected: false),
        RevealCase(
            label: "staff extension over", dueInHours: -25, slipDaysEnabled: true,
            staffExtensionInHours: -1, expected: true),
        RevealCase(label: "no deadline, open", dueInHours: nil, isOpen: true, expected: true),
        RevealCase(label: "unpublished draft", dueInHours: nil, expected: false),
        RevealCase(
            label: "deadline override active", dueInHours: -25, isOpen: true,
            overrideActive: true, expected: false),
    ]

    @Test(arguments: cases)
    func theDashboardAndTheServingRoutesAgree(_ revealCase: RevealCase) async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            let course = try await wrMakeCourse(on: app)
            course.slipDaysEnabled = revealCase.slipDaysEnabled
            course.slipDaysPerStudent = 2
            course.slipDayExtensionHours = 24
            try await course.save(on: app.db)
            let setupID = "setup_parity"
            try await wrInsertSetup(id: setupID, on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: setupID, title: "Parity Lab", isOpen: revealCase.isOpen,
                dueAt: revealCase.dueInHours.map { Date(timeIntervalSinceNow: $0 * 3600) },
                on: app)
            assignment.solutionVisibility = revealCase.policy
            assignment.deadlineOverrideActive = revealCase.overrideActive
            try await assignment.save(on: app.db)

            for _ in 0..<revealCase.spends {
                _ = try await SlipDayStore.spend(
                    userID: try student.requireID(), assignment: assignment,
                    policy: course.slipDayPolicy, on: app.db)
            }
            if let hours = revealCase.staffExtensionInHours {
                let ext = APIAssignmentExtension(
                    assignmentID: try assignment.requireID(),
                    userID: try student.requireID(),
                    extendedDueAt: Date(timeIntervalSinceNow: hours * 3600),
                    note: "accommodation", grantedByUserID: nil)
                try await ext.save(on: app.db)
            }

            let now = Date()
            let served = try await solutionVisibleToStudent(
                assignment: assignment, user: student, on: app.db, now: now)

            // The dashboard's inputs, loaded the way the dashboard loads them.
            let courseID = try course.requireID()
            let slipDay = try await WebRoutes.loadSlipDayDashboardData(
                user: student, activeCourseUUID: courseID, isActiveCourseStaff: false,
                allAssignments: [assignment], db: app.db)
            let extensionDueAt = try await WebRoutes.loadExtensionDueDates(
                user: student, allAssignments: [assignment], db: app.db)[setupID]
            let dashboard = solutionVisibleToStudent(
                assignment: assignment,
                extensionDueAt: extensionDueAt,
                slipDay: slipDay.claimState(forSetupID: setupID, assignment: assignment),
                now: now)

            #expect(served == revealCase.expected, "serving routes")
            #expect(dashboard == revealCase.expected, "dashboard")
        }
    }
}
