// The student dashboard and the server gates share one rule each (#2259, items
// 3 and 6).
//
// The dashboard decides whether to show "Submit" and "View solution" from data
// it has preloaded for every row, so that it runs no per-row query. It used to
// rebuild the server's rules by hand from that data. The copies agreed, but a
// guard added to the server only would make the dashboard offer a link that
// the server refuses, or hide one that works. The rules are now pure functions
// that take resolved inputs: the server loads the inputs and calls them, and
// the dashboard passes its preloaded inputs to the same functions.
//
// These tests check both halves of that contract: the database forms give the
// same answer as the pure rules on the same cases, and the dashboard calls the
// pure rules rather than a copy.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) struct DeadlineRuleSharingTests {

    /// One assignment state and one optional extension, as offsets in hours
    /// from now.
    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let isOpen: Bool
        let dueInHours: Double?
        let extensionInHours: Double?
        var overrideActive = false
        var solutionVisibility: SolutionVisibility = .afterDue
        var preview = false
        /// Slip days on in the course (2 days of 24 hours), so a claim window
        /// can hold the reveal back.
        var slipDays = false

        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(label: "open, before the deadline", isOpen: true, dueInHours: 24, extensionInHours: nil),
        Case(label: "closed at the deadline", isOpen: false, dueInHours: -2, extensionInHours: nil),
        Case(label: "closed at the deadline, extension active", isOpen: false, dueInHours: -2, extensionInHours: 5),
        Case(label: "closed at the deadline, extension lapsed", isOpen: false, dueInHours: -10, extensionInHours: -1),
        Case(label: "closed before the deadline (manual)", isOpen: false, dueInHours: 24, extensionInHours: nil),
        Case(
            label: "re-opened after the deadline", isOpen: true, dueInHours: -2, extensionInHours: nil,
            overrideActive: true),
        Case(label: "no deadline, open", isOpen: true, dueInHours: nil, extensionInHours: nil),
        Case(label: "no deadline, closed", isOpen: false, dueInHours: nil, extensionInHours: nil),
        Case(
            label: "closed at the deadline, reveal off", isOpen: false, dueInHours: -2, extensionInHours: nil,
            solutionVisibility: .hidden),
        Case(label: "preview, before the deadline", isOpen: true, dueInHours: 24, extensionInHours: nil, preview: true),
        Case(label: "preview, after the deadline", isOpen: false, dueInHours: -2, extensionInHours: nil, preview: true),
        Case(
            label: "closed at the deadline, slip-day window open", isOpen: false, dueInHours: -2,
            extensionInHours: nil, slipDays: true),
        Case(
            label: "closed at the deadline, slip-day window lapsed", isOpen: false, dueInHours: -30,
            extensionInHours: nil, slipDays: true),
    ]

    /// Seeds the case for an enrolled student in a course with slip days off,
    /// and returns the student, the assignment and the raw extension date.
    private func seed(_ testCase: Case, on app: Application) async throws -> (APIUser, APIAssignment, Date?) {
        let now = Date()
        _ = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        if testCase.slipDays {
            let course = try await wrMakeCourse(on: app)
            course.slipDaysEnabled = true
            course.slipDaysPerStudent = 2
            course.slipDayExtensionHours = 24
            try await course.save(on: app.db)
        }
        try await wrInsertSetup(id: "setup_rule_sharing", on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: "setup_rule_sharing", title: "Rule sharing", isOpen: testCase.isOpen,
            dueAt: testCase.dueInHours.map { now.addingTimeInterval($0 * 3600) }, on: app)
        assignment.deadlineOverrideActive = testCase.overrideActive
        assignment.solutionVisibility = testCase.solutionVisibility
        if testCase.preview { assignment.visibility = .preview }
        try await assignment.save(on: app.db)

        let extensionDueAt = testCase.extensionInHours.map { now.addingTimeInterval($0 * 3600) }
        if let extensionDueAt {
            try await APIAssignmentExtension(
                assignmentID: try assignment.requireID(), userID: try student.requireID(),
                extendedDueAt: extensionDueAt
            ).save(on: app.db)
        }
        return (student, assignment, extensionDueAt)
    }

    @Test(arguments: cases, [false, true])
    func theSubmitGateAndTheDashboardRuleAgree(_ testCase: Case, isStaff: Bool) async throws {
        try await withWebRoutesApp { app in
            let (student, assignment, extensionDueAt) = try await seed(testCase, on: app)
            let now = Date()
            let server = try await isAssignmentEffectivelyOpenResolved(
                assignment, for: student, isStaff: isStaff, on: app.db, now: now)
            let dashboard = isAssignmentOpenForViewer(
                assignment, isStaff: isStaff, extensionDueAt: extensionDueAt, now: now)
            #expect(server == dashboard)
        }
    }

    @Test(arguments: cases)
    func theSolutionGateAndTheDashboardRuleAgree(_ testCase: Case) async throws {
        try await withWebRoutesApp { app in
            let (student, assignment, extensionDueAt) = try await seed(testCase, on: app)
            let now = Date()
            let server = try await solutionVisibleToStudent(
                assignment: assignment, user: student, on: app.db, now: now)
            let ceiling = try await slipDayClaimWindowCeiling(
                for: assignment, user: student, extensionDueAt: extensionDueAt, on: app.db, now: now)
            let dashboard = solutionVisibleToStudent(
                assignment: assignment,
                effectiveDueAt: laterDeadline(baseline: assignment.dueAt, extensionDueAt: extensionDueAt),
                slipDayClaimCeiling: ceiling, now: now)
            #expect(server == dashboard)
        }
    }

    /// The case the claim ceiling exists for: the deadline has passed, but the
    /// student could still buy a day. Both forms hide the solution, and it is
    /// the ceiling that hides it.
    @Test func anOpenSlipDayWindowHoldsTheRevealBack() async throws {
        let testCase = try #require(Self.cases.first { $0.label == "closed at the deadline, slip-day window open" })
        try await withWebRoutesApp { app in
            let (student, assignment, extensionDueAt) = try await seed(testCase, on: app)
            let now = Date()
            let ceiling = try await slipDayClaimWindowCeiling(
                for: assignment, user: student, extensionDueAt: extensionDueAt, on: app.db, now: now)
            #expect(ceiling != nil)
            #expect(
                try await solutionVisibleToStudent(assignment: assignment, user: student, on: app.db, now: now)
                    == false)
            #expect(
                solutionVisibleToStudent(
                    assignment: assignment, effectiveDueAt: assignment.dueAt, slipDayClaimCeiling: ceiling,
                    now: now) == false)
            #expect(
                solutionVisibleToStudent(
                    assignment: assignment, effectiveDueAt: assignment.dueAt, slipDayClaimCeiling: nil,
                    now: now))
        }
    }

    /// The dashboard must call the shared rules, not rebuild them. A guard
    /// typed into the dashboard row builder is how the two would drift again.
    @Test func theDashboardRowBuilderCallsTheSharedRules() throws {
        let url = repositoryRoot.appendingPathComponent(
            "Sources/APIServer/Routes/Web/WebRoutes+IndexRows.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("isAssignmentOpenForViewer("))
        #expect(code.contains("solutionVisibleToStudent("))
        #expect(!code.contains("submissionGate("), "Build the submit decision with isAssignmentOpenForViewer.")
        #expect(!code.contains(".solutionVisibility"), "Build the reveal decision with solutionVisibleToStudent.")
        #expect(!code.contains("isAssignmentOpenForUser("), "Build the submit decision with isAssignmentOpenForViewer.")
    }
}
