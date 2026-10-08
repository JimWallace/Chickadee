// APIServer/Services/ContentEditEffects.swift
//
// The steps that follow an authoring edit, for the web editor and the MCP tools
// alike (#2259, item 1).
//
// The web script routes used to leave these steps to the browser: after a
// suite-table delete, the page sent `PUT /suite`, and that request re-graded
// and re-validated. The support-file delete sent no such request, so it neither
// re-graded nor re-validated, while the MCP `delete_support_file` tool did both.
// A test that imported the deleted helper then failed for every student while
// the assignment kept its old `validationStatus`. One function, called by each
// write path, keeps the two surfaces in step.
//
// Closing is not part of it. MCP closes an open assignment on every content
// edit and the web live editor does not; that difference is a stated decision
// (`ContentEditClose.swift`, header), so each caller keeps its own close.

import Fluent
import Foundation
import Vapor

/// What an authoring edit can change, which decides the steps after it.
enum ContentEditKind: Sendable {
    /// The edit can change a grade (scripts, families, checks, support files):
    /// re-grade existing submissions when the manifest changed, then
    /// re-validate.
    case gradeAffecting
    /// The edit only moves or re-tags tests: re-validate, but do not re-grade.
    case placementOnly
}

/// Re-grades and re-validates after an authoring edit, as `kind` requires, and
/// returns the number of submissions re-queued.
///
/// Best-effort: the edit has already persisted, so a failure here is logged
/// and never fails the edit. `actingUserID` attributes the re-grade and the
/// validation run. An MCP caller must pass it, because a bearer-authenticated
/// request has no session user (see `scheduleValidationAfterSuiteEdit`).
///
/// The re-grade runs on `req.db`, the privileged default pool, also for MCP:
/// it changes student submission rows as a system re-grade, not as
/// agent-facing data access.
@discardableResult
func applyContentEditEffects(
    _ kind: ContentEditKind,
    assignment: APIAssignment,
    setup: APITestSetup,
    actingUserID: UUID?,
    req: Request
) async -> Int {
    var requeued = 0
    if kind == .gradeAffecting {
        do {
            requeued = try await retestSubmissionsIfManifestChanged(
                setup: setup, triggeredBy: actingUserID, on: req.db)
        } catch {
            req.logger.warning("content-edit auto-retest failed: \(error)")
        }
    }
    // Debounced: a no-op when a validation run is already pending.
    await scheduleValidationAfterSuiteEdit(
        req: req, assignment: assignment, submitterUserID: actingUserID)
    return requeued
}
