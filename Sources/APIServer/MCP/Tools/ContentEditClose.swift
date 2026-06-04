// APIServer/MCP/Tools/ContentEditClose.swift
//
// Shared post-edit step for the MCP content-authoring write tools.
//
// A content edit (suite metadata, pattern family, raw script, starter notebook,
// or reference solution) can change what the suite grades, so it re-runs
// validation — and, matching the web "Save" button (`saveEditedAssignment`,
// which sets `isOpen = false` on every save), it CLOSES a currently-open
// assignment. The student submission gate (`isAssignmentOpenForUser`) keys off
// `isOpen`, not `validationStatus`, so leaving an edited assignment open would
// let students submit against a not-yet-revalidated — possibly broken — suite.
// Closing holds them out until the instructor re-opens with
// `update_assignment(isOpen: true)`, which is itself refused until validation
// passes.
//
// This is persisted as its own save rather than folded into
// `scheduleValidationAfterSuiteEdit`: that helper is debounced and skips its own
// save when a validation is already pending, and it is *also* the web suite
// editor's path, where the live-edit UX deliberately does not close.

import Fluent

/// Closes `assignment` if it is currently open, persisting the change, and
/// reports whether it did. A no-op returning `false` when already closed, so a
/// tool can surface "did this edit close the assignment" to the agent.
@discardableResult
func closeOpenAssignmentForContentEdit(
    _ assignment: APIAssignment, on db: any Database
) async throws -> Bool {
    guard assignment.isOpen else { return false }
    assignment.isOpen = false
    try await assignment.save(on: db)
    return true
}
