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

/// Re-queues every student submission on `setup` for regrade after a content
/// edit that can change a grade — the automatic equivalent of an instructor
/// clicking "Retest all" after editing the suite. Runs the same
/// `retestAllSubmissionsForSetup` path the web button uses, so the agent leaves
/// existing submissions graded against the new suite rather than against the old
/// one.
///
/// Gated on a *real* manifest change: compares `manifestHash(setup.manifest)`
/// (the post-edit manifest, which `applyPatternFamilies` has already written onto
/// `setup`) against `setup.lastRetestedManifestHash`, so a no-op edit doesn't fan
/// out, and bumps the stored hash on success so a later cosmetic save won't
/// duplicate the work. Idempotent against in-flight retests (`force: false` skips
/// rows already pending/assigned). Best-effort: the edit has already persisted,
/// so a retest failure is logged, never thrown. Returns the number re-queued.
///
/// Call this only from tools whose edit can change an outcome (create/delete/edit
/// of tests, families, checks, or script bodies/points) — not from pure
/// placement edits like `move_suite_item`, which only reorder/retag and never
/// change a grade.
@discardableResult
func retestSubmissionsAfterContentEdit(setup: APITestSetup, context: ToolContext) async -> Int {
    let currentHash = manifestHash(setup.manifest)
    guard setup.lastRetestedManifestHash != currentHash else { return 0 }
    do {
        let actingUser = try await context.requireEligibleSubject(tool: "retest")
        let count = try await retestAllSubmissionsForSetup(
            setupID: try setup.requireID(),
            triggeredBy: actingUser.id,
            on: context.db,
            force: false)
        setup.lastRetestedManifestHash = currentHash
        try await setup.save(on: context.db)
        return count
    } catch {
        context.logger.warning("retestSubmissionsAfterContentEdit failed: \(error)")
        return 0
    }
}
