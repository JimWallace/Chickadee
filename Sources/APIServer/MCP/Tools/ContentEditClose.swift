// APIServer/MCP/Tools/ContentEditClose.swift
//
// Shared post-edit step for the MCP content-authoring write tools.
//
// A content edit (suite metadata, pattern family, raw script, starter notebook,
// or reference solution) can change what the suite grades, so it re-runs
// validation — and, matching the web "Save" button (`saveEditedAssignment`,
// which closes on every save), it CLOSES a currently-open assignment. The
// student submission gate keys off visibility (`.open`), not `validationStatus`,
// so leaving an edited assignment open would let students submit against a
// not-yet-revalidated — possibly broken — suite. Closing holds them out until
// the instructor re-opens with `update_assignment`, which is itself refused
// until validation passes. (A `.preview` assignment is staff-only and already
// hidden from students, so it is left as-is — editing it is not a student-facing
// risk and must not silently kick it out of preview.)
//
// This is persisted as its own save rather than folded into
// `scheduleValidationAfterSuiteEdit`: that helper is debounced and skips its own
// save when a validation is already pending, and it is *also* the web suite
// editor's path, where the live-edit UX deliberately does not close.

import Core
import Fluent
import Vapor

/// Closes `assignment` if it is currently open, persisting the change, and
/// reports whether it did. A no-op returning `false` when not open, so a tool
/// can surface "did this edit close the assignment" to the agent.
@discardableResult
func closeOpenAssignmentForContentEdit(
    _ assignment: APIAssignment, on db: any Database
) async throws -> Bool {
    guard assignment.visibility == .open else { return false }
    assignment.visibility = .closed
    try await assignment.save(on: db)
    return true
}

/// MCP wrapper around `retestSubmissionsIfManifestChanged` (defined alongside
/// `retestAllSubmissionsForSetup`): resolves the acting subject for attribution
/// and runs best-effort — the edit has already persisted, so a retest failure is
/// logged, never thrown. See that function for the gating/idempotency contract.
///
/// Call this only from tools whose edit can change an outcome (create/delete/edit
/// of tests, families, checks, or script bodies/points) — not from pure
/// placement edits like `move_suite_item`, which only reorder/re-tag and never
/// change a grade. Returns the number of submissions re-queued.
@discardableResult
func retestSubmissionsAfterContentEdit(setup: APITestSetup, context: ToolContext) async -> Int {
    do {
        let actingUser = try await context.requireEligibleSubject(tool: "retest")
        return try await retestSubmissionsIfManifestChanged(
            setup: setup, triggeredBy: actingUser.id, on: context.db)
    } catch {
        context.logger.warning("retestSubmissionsAfterContentEdit failed: \(error)")
        return 0
    }
}

/// Runs `applySuiteEdit` and maps web-layer failures (`WebAssignmentError`,
/// `AbortError`) to `MCPToolError` so the agent sees a structured, actionable
/// error rather than an opaque protocol-level internal error.
func applySuiteEditMapped(
    setup: APITestSetup, body: SuitePayload, tool: String, on db: any Database
) async throws {
    do {
        try await applySuiteEdit(setup: setup, body: body, on: db)
    } catch let error as WebAssignmentError {
        throw MCPToolError.from(error, tool: tool)
    } catch let error as any AbortError {
        throw MCPToolError.from(error, tool: tool)
    }
}

/// The standard finalize step shared by content-edit tools: close a
/// currently-open assignment (so students can't submit against a
/// not-yet-revalidated suite), optionally re-grade existing submissions, then
/// re-kick (debounced) validation. Returns whether the assignment was closed.
///
/// `retest: true` for edits that can change a grade (scripts, families, checks,
/// solution); `retest: false` for placement/metadata-only edits (e.g.
/// `move_suite_item`) that only reorder or re-tag and never change an outcome.
/// The close→retest→revalidate ordering is the invariant documented on
/// `closeOpenAssignmentForContentEdit` / `retestSubmissionsAfterContentEdit`.
@discardableResult
func finalizeContentEdit(
    assignment: APIAssignment, setup: APITestSetup, context: ToolContext, retest: Bool
) async throws -> Bool {
    let closed = try await closeOpenAssignmentForContentEdit(assignment, on: context.db)
    if retest {
        await retestSubmissionsAfterContentEdit(setup: setup, context: context)
    }
    await scheduleValidationAfterSuiteEdit(req: context.request, assignment: assignment)
    return closed
}
