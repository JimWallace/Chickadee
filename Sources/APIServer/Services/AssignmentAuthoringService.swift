// APIServer/Services/AssignmentAuthoringService.swift
//
// Shared, transport-agnostic assignment-authoring operations. Both the web
// routes and the MCP tools call these so the two paths can't drift (the same
// validation guards, deadline-override semantics, and side effects apply
// however the edit arrives). This is the seed of the authoring service layer
// described in docs/mcp-authoring-roadmap.md (Phase 0).

import Fluent
import Foundation
import Vapor

/// Domain errors from assignment-authoring operations, mapped to transport
/// errors by callers (`WebAssignmentError` on the web, `MCPToolError` over MCP).
enum AssignmentAuthoringError: Error, Sendable, Equatable {
    /// Opening was refused because runner validation has not passed.
    case validationNotPassed
    /// The source assignment's test setup files (zip) could not be copied.
    case setupCopyFailed(reason: String)
}

/// A freshly authored assignment + its new test setup, returned by the
/// creation operations (`cloneAssignment`, `createAssignment`).
struct AuthoredAssignment: Sendable {
    let assignment: APIAssignment
    let setup: APITestSetup
}

/// How a metadata update should treat the due date (absent / clear / set).
enum DueDateUpdate: Sendable, Equatable {
    case unchanged
    case clear
    case set(Date)
}

enum AssignmentAuthoringService {
    /// Opens or closes an assignment for student submissions.
    ///
    /// Mirrors the instructor dashboard exactly: opening requires runner
    /// validation to have passed, and sets `deadlineOverrideActive` when the
    /// due date is already past — otherwise the periodic auto-close sweep would
    /// immediately re-close the assignment. Closing simply clears `isOpen`.
    /// This is metadata-only: it never changes the manifest, so it does not
    /// trigger a regrade.
    static func setOpenState(
        _ assignment: APIAssignment,
        open: Bool,
        on db: Database,
        now: Date = Date()
    ) async throws {
        try applyOpenState(assignment, open: open, now: now)
        try await assignment.save(on: db)
    }

    /// Applies any combination of title / due-date / open-state changes in a
    /// single save, with the same side effects as the instructor editor: a
    /// due-date change re-normalises `deadlineOverrideActive`, and opening
    /// re-derives it from the (possibly just-changed) due date. Metadata-only —
    /// never touches the manifest, so it does not trigger a regrade. Throws
    /// `validationNotPassed` if `open` is true before validation has passed.
    static func updateMetadata(
        _ assignment: APIAssignment,
        title: String? = nil,
        dueAt: DueDateUpdate = .unchanged,
        open: Bool? = nil,
        on db: Database,
        now: Date = Date()
    ) async throws {
        if let title {
            assignment.title = title
        }
        switch dueAt {
        case .unchanged:
            break
        case .clear:
            assignment.dueAt = nil
            assignment.deadlineOverrideActive = normalizedDeadlineOverrideAfterDueDateChange(
                dueAt: nil, existingOverride: assignment.deadlineOverrideActive ?? false)
        case .set(let date):
            assignment.dueAt = date
            assignment.deadlineOverrideActive = normalizedDeadlineOverrideAfterDueDateChange(
                dueAt: date, existingOverride: assignment.deadlineOverrideActive ?? false)
        }
        if let open {
            try applyOpenState(assignment, open: open, now: now)
        }
        try await assignment.save(on: db)
    }

    /// Duplicates an assignment into `targetCourseID` under `newTitle`: the
    /// source test setup's zip (+ optional notebook) is copied to a fresh setup
    /// id, the manifest is carried over verbatim, and a new assignment is
    /// allocated with its own public id + course-unique slug.
    ///
    /// The clone always starts **closed and unvalidated** (no `isOpen`, no
    /// `validationStatus`, no due date) — the instructor (or a follow-up tool
    /// call) re-validates and opens it. Because it's a brand-new setup with no
    /// submissions, nothing is re-graded. Mirrors the per-assignment slice of
    /// the admin `copyCourse` flow so the two clone paths can't drift.
    static func cloneAssignment(
        source: APIAssignment,
        sourceSetup: APITestSetup,
        newTitle: String,
        targetCourseID: UUID,
        setupsDirectory: String,
        on db: Database
    ) async throws -> AuthoredAssignment {
        let newSetupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let fm = FileManager.default

        let dstZip = setupsDirectory + "\(newSetupID).zip"
        do {
            try fm.copyItem(atPath: sourceSetup.zipPath, toPath: dstZip)
        } catch {
            throw AssignmentAuthoringError.setupCopyFailed(reason: "\(error)")
        }

        var newNotebookPath: String?
        if let srcNotebook = sourceSetup.notebookPath, fm.fileExists(atPath: srcNotebook) {
            let dstNotebook = setupsDirectory + "\(newSetupID).ipynb"
            do {
                try fm.copyItem(atPath: srcNotebook, toPath: dstNotebook)
                newNotebookPath = dstNotebook
            } catch {
                try? fm.removeItem(atPath: dstZip)
                throw AssignmentAuthoringError.setupCopyFailed(reason: "\(error)")
            }
        }

        let newSetup = APITestSetup(
            id: newSetupID, manifest: sourceSetup.manifest, zipPath: dstZip,
            notebookPath: newNotebookPath, courseID: targetCourseID)

        do {
            try await newSetup.save(on: db)
            let assignment = try await createAssignmentWithUniquePublicID(
                on: db,
                testSetupID: newSetupID,
                title: newTitle,
                dueAt: nil,
                isOpen: false,
                sortOrder: nil,
                validationStatus: nil,
                validationSubmissionID: nil,
                courseID: targetCourseID)
            return AuthoredAssignment(assignment: assignment, setup: newSetup)
        } catch {
            // Roll back the copied files so a failed clone leaves no orphans.
            try? fm.removeItem(atPath: dstZip)
            if let newNotebookPath { try? fm.removeItem(atPath: newNotebookPath) }
            throw error
        }
    }

    /// Creates a brand-new browser-graded, notebook-based assignment from
    /// scratch: a minimal empty-suite manifest + an empty runner zip + the
    /// supplied notebook, then a fresh assignment row (closed, unvalidated, no
    /// due date). The agent fills in tests afterwards with the suite/family
    /// tools. Mirrors the per-setup work the web new-assignment publish does,
    /// minus the draft scaffolding, so the paths can't drift.
    ///
    /// Empty suite ⇒ no validation is queued, so a from-scratch assignment can
    /// be opened by the instructor without a runner once it has content.
    static func createAssignment(
        courseID: UUID,
        title: String,
        notebookData: Data,
        setupsDirectory: String,
        on db: Database
    ) async throws -> AuthoredAssignment {
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = setupsDirectory + "\(setupID).zip"
        do {
            _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        } catch {
            throw AssignmentAuthoringError.setupCopyFailed(reason: "\(error)")
        }

        let manifest =
            #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: nil,
            courseID: courseID)

        do {
            try await setup.save(on: db)
            try await writeAssignmentNotebook(
                setup: setup, notebookData: notebookData, setupsDirectory: setupsDirectory, on: db)
            let assignment = try await createAssignmentWithUniquePublicID(
                on: db,
                testSetupID: setupID,
                title: title,
                dueAt: nil,
                isOpen: false,
                sortOrder: nil,
                validationStatus: nil,
                validationSubmissionID: nil,
                courseID: courseID)
            return AuthoredAssignment(assignment: assignment, setup: setup)
        } catch {
            // Roll back the files written so a failed create leaves no orphans.
            try? FileManager.default.removeItem(atPath: zipPath)
            if let nb = setup.notebookPath { try? FileManager.default.removeItem(atPath: nb) }
            throw error
        }
    }

    /// Replaces a test setup's flat starter notebook with `notebookData`,
    /// applying the same JupyterLite kernel normalization + flat-file write the
    /// web editor's no-upload Save path uses (`persistAssignmentNotebook`). The
    /// setup's `notebookPath` is set (creating `<setupID>.ipynb` when absent)
    /// and the setup is saved.
    ///
    /// The setup zip is intentionally *not* rebuilt — reads prefer the flat
    /// file (`notebookData(for:)`), the zip stays archival, and existing student
    /// working copies are left untouched so in-progress work isn't clobbered.
    /// Callers that want the validation loop closed call
    /// `scheduleValidationAfterSuiteEdit` afterwards, matching the web Save.
    static func writeAssignmentNotebook(
        setup: APITestSetup,
        notebookData: Data,
        setupsDirectory: String,
        on db: Database
    ) async throws {
        let normalized = normalizeNotebookForJupyterLite(notebookData)
        let path =
            setup.notebookPath ?? (setupsDirectory + "\((setup.id ?? "unknown")).ipynb")
        do {
            try normalized.write(to: URL(fileURLWithPath: path))
        } catch {
            throw AssignmentAuthoringError.setupCopyFailed(reason: "\(error)")
        }
        setup.notebookPath = path
        try await setup.save(on: db)
    }

    /// Mutates open-state in memory (no save). Opening requires validation to
    /// have passed and sets the deadline override when the due date is past.
    private static func applyOpenState(_ assignment: APIAssignment, open: Bool, now: Date) throws {
        if open {
            guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
                throw AssignmentAuthoringError.validationNotPassed
            }
            assignment.isOpen = true
            assignment.deadlineOverrideActive = deadlineOverrideValueForInstructorOpen(
                dueAt: assignment.dueAt, now: now)
        } else {
            assignment.isOpen = false
        }
    }
}
