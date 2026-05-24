// APIServer/Services/AssignmentAuthoringService.swift
//
// Shared, transport-agnostic assignment-authoring operations. Both the web
// routes and the MCP tools call these so the two paths can't drift (the same
// validation guards, deadline-override semantics, and side effects apply
// however the edit arrives). This is the seed of the authoring service layer
// described in docs/mcp-authoring-roadmap.md (Phase 0).

import Fluent
import Vapor

/// Domain errors from assignment-authoring operations, mapped to transport
/// errors by callers (`WebAssignmentError` on the web, `MCPToolError` over MCP).
enum AssignmentAuthoringError: Error, Sendable, Equatable {
    /// Opening was refused because runner validation has not passed.
    case validationNotPassed
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
