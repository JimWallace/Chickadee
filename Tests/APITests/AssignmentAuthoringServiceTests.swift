// Tests for AssignmentAuthoringService.setOpenState — the shared open/close
// logic used by both the instructor dashboard and the MCP update_assignment
// tool.

import Core
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
            assignment.visibility = .open
            try await assignment.save(on: app.db)
            try await AssignmentAuthoringService.setOpenState(assignment, open: false, on: app.db)
            #expect(assignment.isOpen == false)
        }
    }

    // MARK: - Three-state visibility (Preview)

    @Test func previewNeedsNoValidation() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Switching to preview is a pure visibility flip — it must not be
            // gated on validation the way opening to students is.
            let assignment = try await makeAssignment(on: app, validationStatus: "pending")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, on: app.db)
            #expect(assignment.visibility == .preview)
            // It is not open to students (the derived flag stays false).
            #expect(assignment.isOpen == false)
        }
    }

    @Test func previewIsOpenForStaffAndClosedForStudents() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, on: app.db)
            let staff = try await makeTestUser(on: app, username: "prof", role: "instructor")
            let student = try await makeTestUser(on: app, username: "stu", role: "student")
            #expect(try await isAssignmentEffectivelyOpen(assignment, for: staff, on: app.db))
            #expect(!(try await isAssignmentEffectivelyOpen(assignment, for: student, on: app.db)))
        }
    }

    @Test func previewThenOpenSucceeds() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, on: app.db)
            try await AssignmentAuthoringService.setVisibility(assignment, .open, on: app.db)
            #expect(assignment.visibility == .open)
        }
    }

    @Test func openToPreviewIsAllowed() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // No one-way restriction: an instructor can pull a live assignment
            // back to staff-only (it just becomes hidden from students again).
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .open, on: app.db)
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, on: app.db)
            #expect(assignment.visibility == .preview)
        }
    }

    @Test func scheduledOpenSweepSkipsPreview() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, on: app.db)
            // A past open date auto-opens a *closed* assignment, but a Preview
            // assignment must stay in its staff-only state.
            assignment.startsAt = Date().addingTimeInterval(-3600)
            try await assignment.save(on: app.db)
            let opened = try await openScheduledAssignment(assignment, on: app.db, logger: app.logger)
            #expect(opened == false)
            #expect(assignment.visibility == .preview)
        }
    }
}
