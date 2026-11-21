// Tests/APITests/Assignments/AssignmentAuthoringServiceTests.swift
//
// `AssignmentAuthoringService`. `setOpenState` is the shared open/close logic
// used by both the instructor dashboard and the MCP update_assignment tool.
//
// `AssignmentAuthoringServiceFailureTests` covers the failure paths of
// creation and clone. Each one throws a domain error or the database error,
// and removes the files it wrote, so a failed create or clone leaves no
// orphan zip or notebook on disk. The success paths are covered by
// `SectionPlacementTests`, `ClonedSolutionSourceTests` and
// `AssignmentVersionLifecycleTests`. Every failure is made with a directory
// that does not exist or a course that does not exist, never with file
// permissions, so the tests behave the same on macOS and Linux.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct AssignmentAuthoringServiceTests {
    /// The audit origin the service functions require (#2489).
    private func audit(_ app: Application) -> VisibilityAudit {
        .web(makeTestRequest(on: app))
    }

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
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app)
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, audit: audit(app), on: app.db)
            #expect(assignment.isOpen)
            #expect(assignment.deadlineOverrideActive == false)
        }
    }

    @Test func openingPastDueSetsDeadlineOverride() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, dueAt: Date().addingTimeInterval(-3600))
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, audit: audit(app), on: app.db)
            #expect(assignment.isOpen)
            // Override must be set, else the auto-close sweep re-closes it.
            #expect(assignment.deadlineOverrideActive == true)
        }
    }

    @Test func openingBeforeDueDoesNotSetOverride() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, dueAt: Date().addingTimeInterval(3600))
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, audit: audit(app), on: app.db)
            #expect(assignment.isOpen)
            #expect(assignment.deadlineOverrideActive == false)
        }
    }

    @Test func openingIsRefusedUntilValidationPasses() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "pending")
            await #expect(throws: AssignmentAuthoringError.validationNotPassed) {
                try await AssignmentAuthoringService.setOpenState(assignment, open: true, audit: audit(app), on: app.db)
            }
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.isOpen == false)
        }
    }

    @Test func openingAllowedWhenValidationPassed() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, audit: audit(app), on: app.db)
            #expect(assignment.isOpen)
        }
    }

    @Test func updateMetadataSetsTitleAndFutureDue() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app)
            let due = Date().addingTimeInterval(86_400)
            try await AssignmentAuthoringService.updateMetadata(
                assignment, title: "New", dueAt: .set(due), audit: audit(app), on: app.db)
            #expect(assignment.title == "New")
            #expect(assignment.dueAt == due)
            #expect(assignment.deadlineOverrideActive == false)
        }
    }

    @Test func updateMetadataClearsDueDate() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, dueAt: Date().addingTimeInterval(86_400))
            try await AssignmentAuthoringService.updateMetadata(
                assignment, dueAt: .clear, audit: audit(app), on: app.db)
            #expect(assignment.dueAt == nil)
        }
    }

    @Test func updateMetadataOpenPastDueSetsOverrideInOneCall() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app)
            try await AssignmentAuthoringService.updateMetadata(
                assignment, dueAt: .set(Date().addingTimeInterval(-3600)), open: true, audit: audit(app), on: app.db)
            #expect(assignment.isOpen)
            #expect(assignment.deadlineOverrideActive == true)
        }
    }

    @Test func closeClearsIsOpen() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app)
            assignment.visibility = .open
            try await assignment.save(on: app.db)
            try await AssignmentAuthoringService.setOpenState(assignment, open: false, audit: audit(app), on: app.db)
            #expect(assignment.isOpen == false)
        }
    }

    // MARK: - Three-state visibility (Preview)

    @Test func previewNeedsNoValidation() async throws {
        try await withTestApp { app in
            // Switching to preview is a pure visibility flip — it must not be
            // gated on validation the way opening to students is.
            let assignment = try await makeAssignment(on: app, validationStatus: "pending")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, audit: audit(app), on: app.db)
            #expect(assignment.visibility == .preview)
            // It is not open to students (the derived flag stays false).
            #expect(assignment.isOpen == false)
        }
    }

    @Test func previewIsOpenForStaffAndClosedForStudents() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, audit: audit(app), on: app.db)
            let staff = try await makeTestUser(on: app, username: "prof", role: "instructor")
            let student = try await makeTestUser(on: app, username: "stu", role: "student")
            // Preview visibility is per-course staff now (#417 Slice G); enrol the
            // staff user as an instructor in the assignment's course.
            try await APICourseEnrollment(
                userID: try staff.requireID(), courseID: assignment.courseID, role: .instructor
            ).save(on: app.db)
            #expect(try await isAssignmentEffectivelyOpen(assignment, for: staff, on: app.db))
            #expect(!(try await isAssignmentEffectivelyOpen(assignment, for: student, on: app.db)))
        }
    }

    @Test func previewThenOpenSucceeds() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, audit: audit(app), on: app.db)
            try await AssignmentAuthoringService.setVisibility(assignment, .open, audit: audit(app), on: app.db)
            #expect(assignment.visibility == .open)
        }
    }

    @Test func openToPreviewIsAllowed() async throws {
        try await withTestApp { app in
            // No one-way restriction: an instructor can pull a live assignment
            // back to staff-only (it just becomes hidden from students again).
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .open, audit: audit(app), on: app.db)
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, audit: audit(app), on: app.db)
            #expect(assignment.visibility == .preview)
        }
    }

    @Test func scheduledOpenSweepPublishesPreview() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "passed")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, audit: audit(app), on: app.db)
            // An open date on a Preview assignment is the staff workflow "test
            // now, publish to students at this time" — the sweep must open it,
            // not strand it in the staff-only state past its open date.
            assignment.startsAt = Date().addingTimeInterval(-3600)
            try await assignment.save(on: app.db)
            let opened = try await openScheduledAssignment(assignment, on: app.db, logger: app.logger)
            #expect(opened)
            #expect(assignment.visibility == .open)
            #expect(assignment.startsAt == nil, "Open date is consumed once it fires")
        }
    }

    @Test func scheduledOpenSweepHoldsPreviewUntilValidationPasses() async throws {
        try await withTestApp { app in
            let assignment = try await makeAssignment(on: app, validationStatus: "pending")
            try await AssignmentAuthoringService.setVisibility(assignment, .preview, audit: audit(app), on: app.db)
            assignment.startsAt = Date().addingTimeInterval(-3600)
            try await assignment.save(on: app.db)
            let opened = try await openScheduledAssignment(assignment, on: app.db, logger: app.logger)
            #expect(opened == false)
            #expect(assignment.visibility == .preview)
            #expect(assignment.startsAt != nil, "Open date stays armed so the sweep retries after validation")
        }
    }
}

// MARK: - Creation and clone failures

@Suite(.serialized) struct AssignmentAuthoringServiceFailureTests {

    private static let notebook = Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)

    /// The file names in `directory`, without the subdirectories that the
    /// test app makes there.
    private func files(in directory: String) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return Set(names.filter { $0.hasSuffix(".zip") || $0.hasSuffix(".ipynb") })
    }

    private func isSetupCopyFailure(_ error: any Error, reasonPrefix: String? = nil) -> Bool {
        guard case .setupCopyFailed(let reason) = error as? AssignmentAuthoringError else { return false }
        guard let reasonPrefix else { return true }
        return reason.hasPrefix(reasonPrefix)
    }

    // MARK: - createAssignment

    @Test func createIntoAMissingSetupsDirectoryIsASetupCopyFailure() async throws {
        try await withTestApp(prefix: "chickadee-aasf-create-dir") { app in
            let courseID = try await makeTestCourse(on: app, code: "AASFDIR").requireID()
            let missing = app.testSetupsDirectory + "missing/"

            await #expect {
                _ = try await AssignmentAuthoringService.createAssignment(
                    courseID: courseID, title: "Lab", language: .python,
                    notebookData: Self.notebook, setupsDirectory: missing, on: app.db)
            } throws: { isSetupCopyFailure($0) }

            #expect(try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count() == 0)
            #expect(try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count() == 0)
        }
    }

    /// The setup row names a course that does not exist, so its save fails
    /// after the zip is written. The zip is removed again.
    @Test func aFailedCreateRemovesTheZipItWrote() async throws {
        try await withTestApp(prefix: "chickadee-aasf-create-rollback") { app in
            let before = try files(in: app.testSetupsDirectory)
            #expect(before.isEmpty)

            let created: AuthoredAssignment?
            do {
                created = try await AssignmentAuthoringService.createAssignment(
                    courseID: UUID(), title: "Lab", language: .r,
                    notebookData: Self.notebook, setupsDirectory: app.testSetupsDirectory, on: app.db)
            } catch {
                // The zip was written: a failure to write it is the domain
                // error, and this one is the database refusing the row.
                #expect(!(error is AssignmentAuthoringError), "unexpected error: \(error)")
                created = nil
            }
            #expect(created == nil, "a setup in a course that does not exist must not save")

            let after = try files(in: app.testSetupsDirectory)
            #expect(after.isEmpty)
            #expect(try await APIAssignment.query(on: app.db).count() == 0)
        }
    }

    // MARK: - writeAssignmentNotebook

    @Test func aNotebookThatCannotBeWrittenIsASetupCopyFailure() async throws {
        try await withTestApp(prefix: "chickadee-aasf-notebook") { app in
            let courseID = try await makeTestCourse(on: app, code: "AASFNB").requireID()
            let setup = try await makeTestSetup(on: app, id: "aasf_nb", courseID: courseID, withNotebook: false)
            setup.notebookPath = app.testSetupsDirectory + "missing/aasf_nb.ipynb"

            await #expect {
                try await AssignmentAuthoringService.writeAssignmentNotebook(
                    setup: setup, notebookData: Self.notebook,
                    setupsDirectory: app.testSetupsDirectory, on: app.db)
            } throws: { isSetupCopyFailure($0) }

            // The stored row still has no notebook.
            let stored = try #require(try await APITestSetup.find("aasf_nb", on: app.db))
            #expect(stored.notebookPath == nil)
        }
    }

    // MARK: - cloneAssignment

    /// The source has a reference solution, and the clone cannot copy it
    /// because the submissions directory does not exist. The clone throws,
    /// names the solution in its reason, creates no assignment, and removes
    /// the setup zip and the notebook it had copied.
    @Test func aCloneWhoseSolutionCannotBeCopiedRemovesItsFiles() async throws {
        try await withTestApp(prefix: "chickadee-aasf-clone") { app in
            let courseID = try await makeTestCourse(on: app, code: "AASFCLONE").requireID()
            let sourceSetup = try await makeTestSetup(on: app, id: "aasf_clone_src", courseID: courseID)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "aasf_clone_src", courseID: courseID, title: "Lab 4")
            let author = try await makeTestUser(on: app, username: "aasf_clone_author", role: "admin")
            let solution = try await makeTestSubmission(
                on: app, id: "sub_aasf_clone", setupID: "aasf_clone_src",
                userID: try author.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            source.validationSubmissionID = try solution.requireID()
            try await source.save(on: app.db)
            let before = try files(in: app.testSetupsDirectory)
            #expect(before == ["aasf_clone_src.zip", "aasf_clone_src.ipynb"])

            await #expect {
                _ = try await AssignmentAuthoringService.cloneAssignment(
                    source: source, sourceSetup: sourceSetup, newTitle: "Lab 4 (Copy)",
                    targetCourseID: courseID,
                    directories: AuthoringDirectories(
                        setups: app.testSetupsDirectory,
                        submissions: app.submissionsDirectory + "missing/"),
                    on: app.db)
            } throws: { isSetupCopyFailure($0, reasonPrefix: "reference solution:") }

            #expect(try files(in: app.testSetupsDirectory) == before)
            let titles = try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).all()
                .map(\.title)
            #expect(titles == ["Lab 4"])
        }
    }
}
