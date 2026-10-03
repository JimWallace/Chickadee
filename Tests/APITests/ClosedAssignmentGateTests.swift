// Tests/APITests/ClosedAssignmentGateTests.swift
//
// The closed-assignment gate as a function over a database (#1732). The
// notebook-page and upload-form tests reach it through a route; these call it
// directly, which its old `Request` parameter did not allow.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct ClosedAssignmentGateTests {

    /// A closed assignment with no past due date is a draft: not visible to
    /// students by its state.
    private static func insertDraft(on app: Application) async throws -> APIAssignment {
        _ = try await arInsertSetup(id: "gate_setup", on: app)
        return try await arInsertAssignment(
            testSetupID: "gate_setup", title: "Unpublished Lab", isOpen: false, on: app)
    }

    private static func participation(
        _ user: APIUser, _ assignment: APIAssignment, on app: Application
    ) async throws -> Bool {
        try await AssignmentParticipationStore.hasParticipation(
            userID: try user.requireID(), assignmentID: try assignment.requireID(), on: app.db)
    }

    @Test func aStudentWhoNeverOpenedAClosedDraftIsSentToTheDashboard() async throws {
        try await withAssignmentRoutesApp { app in
            let student = try await arInsertStudent(on: app)
            let draft = try await Self.insertDraft(on: app)

            let gate = try await closedAssignmentGate(
                userID: try student.requireID(), assignment: draft, isClosed: true,
                viewerIsCourseStaff: false, on: app.db)

            #expect(gate == .redirectToDashboard)
            #expect(try await !Self.participation(student, draft, on: app))
        }
    }

    @Test func aStudentWhoOpenedItBeforeMayReturnAfterItCloses() async throws {
        try await withAssignmentRoutesApp { app in
            let student = try await arInsertStudent(on: app)
            let draft = try await Self.insertDraft(on: app)
            try await AssignmentParticipationStore.recordFirstAccess(
                userID: try student.requireID(), assignmentID: try draft.requireID(), on: app.db)

            let gate = try await closedAssignmentGate(
                userID: try student.requireID(), assignment: draft, isClosed: true,
                viewerIsCourseStaff: false, on: app.db)

            #expect(gate == .allowed)
        }
    }

    @Test func courseStaffPassAndAreNotRecorded() async throws {
        try await withAssignmentRoutesApp { app in
            let staff = try await arInsertStudent(username: "gate_ta", on: app)
            let draft = try await Self.insertDraft(on: app)

            let gate = try await closedAssignmentGate(
                userID: try staff.requireID(), assignment: draft, isClosed: true,
                viewerIsCourseStaff: true, on: app.db)

            #expect(gate == .allowed)
            #expect(try await !Self.participation(staff, draft, on: app))
        }
    }

    @Test func aStudentOnAnOpenAssignmentPassesAndIsRecorded() async throws {
        try await withAssignmentRoutesApp { app in
            let student = try await arInsertStudent(on: app)
            _ = try await arInsertSetup(id: "gate_open_setup", on: app)
            let open = try await arInsertAssignment(
                testSetupID: "gate_open_setup", title: "Open Lab", isOpen: true, on: app)

            let gate = try await closedAssignmentGate(
                userID: try student.requireID(), assignment: open, isClosed: false,
                viewerIsCourseStaff: false, on: app.db)

            #expect(gate == .allowed)
            #expect(try await Self.participation(student, open, on: app))
        }
    }
}
