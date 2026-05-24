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
        try await assignment.save(on: db)
    }
}
