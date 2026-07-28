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
        // Re-queue runs on the privileged default pool, not the MCP pool: it
        // reads and flips STUDENT submission rows (a system regrade, not
        // agent-facing data access), so it must not depend on the MCP path's
        // (optionally least-privilege) connection. With no dedicated MCP pool
        // configured this is the same connection, so behaviour is unchanged.
        return try await retestSubmissionsIfManifestChanged(
            setup: setup, triggeredBy: actingUser.id, on: context.request.db)
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
/// `retest: true` for edits that can change a grade (scripts, families,
/// checks); `retest: false` for placement/metadata-only edits (e.g.
/// `move_suite_item`) that only reorder or re-tag and never change an outcome.
/// `update_solution` is the one named exemption from this chokepoint: it
/// enqueues its own validation carrying the new solution (this helper's
/// re-kick would validate the old one) and closes via
/// `closeOpenAssignmentForContentEdit` directly; a solution-only edit never
/// changes the manifest, so the manifest-gated retest would be a no-op —
/// matching the web save path (#1115). `MCPContentEditCoverageTests` pins the
/// full classification. The close→retest→revalidate ordering is the invariant
/// documented on `closeOpenAssignmentForContentEdit` /
/// `retestSubmissionsAfterContentEdit`.
@discardableResult
func finalizeContentEdit(
    assignment: APIAssignment, setup: APITestSetup, context: ToolContext, retest: Bool
) async throws -> ContentEditFinalizeResult {
    let closed = try await closeOpenAssignmentForContentEdit(assignment, on: context.db)
    var requeued = 0
    if retest {
        requeued = await retestSubmissionsAfterContentEdit(setup: setup, context: context)
    }
    // Pass the acting subject explicitly: an MCP request is bearer-authenticated
    // with no session `APIUser`, so the helper's `req.auth` fallback would throw
    // 401 inside its swallow-all catch and the re-validation would silently
    // never be enqueued (the assignment kept its stale validationStatus).
    let submitterUserID = try? await context.requireEligibleSubject(tool: "validate").id
    await scheduleValidationAfterSuiteEdit(
        req: context.request, assignment: assignment, submitterUserID: submitterUserID)
    return ContentEditFinalizeResult(assignmentClosed: closed, submissionsRequeued: requeued)
}

/// What `finalizeContentEdit` did, so a tool can report both consequences.
///
/// The re-queue count comes from the retest fan-out's own return value rather
/// than from a submissions query. Two reasons: the MCP tool surface may not
/// name the student-data models at all (`MCPStudentDataWallTests` enforces it
/// by source scan — including in comments, which is why none appear here), and
/// the fan-out's number is the accurate one anyway. Counting pending rows would
/// also sweep in work queued for unrelated reasons.
struct ContentEditFinalizeResult: Sendable {
    let assignmentClosed: Bool
    /// Submissions re-queued to re-grade against the edited suite; 0 when the
    /// edit was placement-only or the manifest did not change.
    let submissionsRequeued: Int
}
