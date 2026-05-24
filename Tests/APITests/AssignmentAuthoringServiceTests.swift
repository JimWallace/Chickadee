// Tests for AssignmentAuthoringService.setOpenState — the shared open/close
// logic used by both the instructor dashboard and the MCP update_assignment
// tool.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct AssignmentAuthoringServiceTests {
    private func makeAssignment(
        on app: Application, dueAt: Date? = nil, validationStatus: String? = nil
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS100", name: "Intro")
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: "setup_open", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_open", courseID: courseID, title: "Lab", dueAt: dueAt,
            isOpen: false)
        if let validationStatus {
            assignment.validationStatus = validationStatus
            try await assignment.save(on: app.db)
        }
        return assignment
    }

    @Test func opensWhenNoDueDateAndNoOverride() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app)
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, on: app.db)
            #expect(assignment.isOpen)
            #expect(assignment.deadlineOverrideActive == false)
        }
    }

    @Test func openingPastDueSetsDeadlineOverride() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, dueAt: Date().addingTimeInterval(-3600))
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, on: app.db)
            #expect(assignment.isOpen)
            // Override must be set, else the auto-close sweep re-closes it.
            #expect(assignment.deadlineOverrideActive == true)
        }
    }

    @Test func openingBeforeDueDoesNotSetOverride() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, dueAt: Date().addingTimeInterval(3600))
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, on: app.db)
            #expect(assignment.isOpen)
            #expect(assignment.deadlineOverrideActive == false)
        }
    }

    @Test func openingIsRefusedUntilValidationPasses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "pending")
            await #expect(throws: AssignmentAuthoringError.validationNotPassed) {
                try await AssignmentAuthoringService.setOpenState(assignment, open: true, on: app.db)
            }
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.isOpen == false)
        }
    }

    @Test func openingAllowedWhenValidationPassed() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, on: app.db)
            #expect(assignment.isOpen)
        }
    }

    @Test func updateMetadataSetsTitleAndFutureDue() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app)
            let due = Date().addingTimeInterval(86_400)
            try await AssignmentAuthoringService.updateMetadata(
                assignment, title: "New", dueAt: .set(due), on: app.db)
            #expect(assignment.title == "New")
            #expect(assignment.dueAt == due)
            #expect(assignment.deadlineOverrideActive == false)
        }
    }

    @Test func updateMetadataClearsDueDate() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, dueAt: Date().addingTimeInterval(86_400))
            try await AssignmentAuthoringService.updateMetadata(assignment, dueAt: .clear, on: app.db)
            #expect(assignment.dueAt == nil)
        }
    }

    @Test func updateMetadataOpenPastDueSetsOverrideInOneCall() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app)
            try await AssignmentAuthoringService.updateMetadata(
                assignment, dueAt: .set(Date().addingTimeInterval(-3600)), open: true, on: app.db)
            #expect(assignment.isOpen)
            #expect(assignment.deadlineOverrideActive == true)
        }
    }

    @Test func closeClearsIsOpen() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app)
            assignment.isOpen = true
            try await assignment.save(on: app.db)
            try await AssignmentAuthoringService.setOpenState(assignment, open: false, on: app.db)
            #expect(assignment.isOpen == false)
        }
    }
}
