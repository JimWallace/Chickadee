// APIServer/MCP/Tools/ContentEditClose.swift
//
// Shared post-edit step for the MCP content-authoring write tools.
//
// A content edit (suite metadata, pattern family, raw script, starter notebook,
// or reference solution) can change what the suite grades, so it re-runs
// validation — and, matching the web "Save" button (`saveEditedAssignment`,
// which closes on every save), it returns the assignment to `.closed`. The
// student submission gate keys off visibility (`.open`), not `validationStatus`,
// so leaving an edited assignment open would let students submit against a
// not-yet-revalidated — possibly broken — suite. A `.preview` assignment is
// closed too: its staff test-submit path is gated on validation, which the edit
// has just invalidated, so it must drop out of the staff-only beta state and be
// re-validated. Closing holds everyone out until the instructor re-opens (or
// re-previews) with `update_assignment`, which is itself refused until
// validation passes.
//
// This is persisted as its own save rather than folded into
// `scheduleValidationAfterSuiteEdit`: that helper is debounced and skips its own
// save when a validation is already pending, and it is *also* the web suite
// editor's path, where the live-edit UX deliberately does not close.

import Core
import Fluent

/// Closes `assignment` if students could currently see it as open or staff are
/// previewing it (visibility != `.closed`), persisting the change, and reports
/// whether it did. A no-op returning `false` when already closed, so a tool can
/// surface "did this edit close the assignment" to the agent.
@discardableResult
func closeOpenAssignmentForContentEdit(
    _ assignment: APIAssignment, on db: any Database
) async throws -> Bool {
    guard assignment.visibility != .closed else { return false }
    assignment.visibility = .closed
    try await assignment.save(on: db)
    return true
}
