// APIServer/Services/GradeOverrides.swift
//
// Shared lookups for the per-student grade override (`APIGradeOverride`,
// keyed on (test_setup, user)).  An override is the student's effective
// grade for an assignment and must replace the runner-computed grade
// everywhere a grade is shown — the student dashboard, the submission
// detail page, the instructor roster/median, the grades CSV, and the
// BrightSpace sync.  These helpers centralise the (setupID, userID) lookup
// so each display site applies the override the same way.

import Fluent
import Foundation
import SQLKit
import Vapor

/// Composite key for one override: a single (test setup, user) pair.
struct GradeOverrideKey: Hashable {
    let setupID: String
    let userID: UUID
}

/// Batch-loads grade overrides for the given test setups in one query,
/// keyed by (setupID, userID).  Callers index by whichever pair they hold
/// in scope.  The value is the override percent (0–100).
func loadGradeOverridePercents(
    setupIDs: some Collection<String>, on db: any Database
) async throws -> [GradeOverrideKey: Int] {
    guard !setupIDs.isEmpty else { return [:] }
    let rows = try await APIGradeOverride.query(on: db)
        .filter(\.$testSetupID ~~ Set(setupIDs))
        .all()
    var map: [GradeOverrideKey: Int] = [:]
    for row in rows {
        map[GradeOverrideKey(setupID: row.testSetupID, userID: row.userID)] = row.overridePercent
    }
    return map
}

/// One-off override lookup for single-submission pages.  Returns the
/// override percent (0–100) for this (setup, user), or nil when none.
func gradeOverridePercent(
    setupID: String, userID: UUID, on db: any Database
) async throws -> Int? {
    try await APIGradeOverride.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$userID == userID)
        .first()?
        .overridePercent
}

/// Converts an override percent into points against a test setup's total
/// possible points (the sum of its suite items' weights), for points-based
/// exports such as the grades CSV and BrightSpace.  Nil when the manifest
/// is missing/malformed or sums to zero.
func gradeOverridePoints(percent: Int, setup: APITestSetup) -> Double? {
    guard let total = suiteTotalPoints(props: setup.decodedManifest()) else { return nil }
    return Double(percent) / 100.0 * total
}

// MARK: - Mutating helpers (shared by every override-setting site)
//
// One student's override is the same row no matter which instructor page set
// it.  Centralising the upsert / clear keeps the per-student grouped view and
// the per-assignment roster from drifting on the side effects that have to
// accompany every change — most importantly re-flagging the student's results
// for BrightSpace sync so the next sweep re-pushes the new effective grade.
// Audit logging stays at the route layer (it needs the `Request`).

/// Upserts the (setup, user) override to `percent`, storing the note and
/// granting instructor, then re-flags the student's results for BrightSpace
/// sync so the next sweep pushes the new effective grade.
func applyGradeOverride(
    testSetupID: String,
    studentUserID: UUID,
    percent: Int,
    note: String?,
    grantedByUserID: UUID?,
    on db: any Database
) async throws {
    // One transaction: the override, the dropped removal and the push flags
    // land together or not at all.
    try await db.transaction { tx in
        let row =
            try await APIGradeOverride.query(on: tx)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$userID == studentUserID)
            .first()
            ?? APIGradeOverride(
                testSetupID: testSetupID,
                userID: studentUserID,
                overridePercent: percent,
                note: note,
                grantedByUserID: grantedByUserID
            )
        row.overridePercent = percent
        row.note = note
        row.grantedByUserID = grantedByUserID
        try await row.save(on: tx)
        // Setting an override (re)establishes a grade — drop any queued removal
        // for this (student, setup) so the sweep doesn't clear a grade we're
        // pushing.
        try await APIBrightSpaceGradeClear.query(on: tx)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$userID == studentUserID)
            .delete()
        try await requestGradePush(.student(studentUserID, override: row), testSetupID: testSetupID, on: tx)
    }
}

/// Clears any (setup, user) override and re-flags the student's results for
/// BrightSpace sync so the next sweep reverts to the runner-computed grade.
/// Returns `true` when a row existed and was removed (the caller uses this to
/// gate the audit-log entry).
@discardableResult
func clearGradeOverride(
    testSetupID: String,
    studentUserID: UUID,
    on db: any Database
) async throws -> Bool {
    // One transaction, as for `applyGradeOverride`.
    try await db.transaction { tx in
        guard
            let existing = try await APIGradeOverride.query(on: tx)
                .filter(\.$testSetupID == testSetupID)
                .filter(\.$userID == studentUserID)
                .first()
        else {
            return false
        }
        try await existing.delete(on: tx)
        // Clearing reverts to the runner-computed grade. For a student with
        // submissions that re-flags their results; for a no-submission student
        // there is no runner grade — so if Chickadee previously pushed a grade
        // for them, queue a removal so the LEARN grade doesn't stay stale.
        try await requestGradePush(.student(studentUserID, override: nil), testSetupID: testSetupID, on: tx)
        try await enqueueGradeClearIfOrphaned(
            testSetupID: testSetupID, studentUserID: studentUserID, on: tx)
        return true
    }
}

/// Queues a BrightSpace grade removal for a (student, setup) that has lost its
/// only Chickadee grade source — no student submissions remain — but ONLY when
/// Chickadee has actually pushed a grade for it (a `success` row in the sync
/// log). That gate is what keeps Chickadee from ever clearing a grade an
/// instructor entered by hand in LEARN. A no-op when the student still has
/// submissions (their runner grade is re-pushed instead) or nothing was synced.
func enqueueGradeClearIfOrphaned(
    testSetupID: String,
    studentUserID: UUID,
    on db: any Database
) async throws {
    let hasSubmissions =
        try await APISubmission.query(on: db)
        .filter(\.$userID == studentUserID)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .first() != nil
    guard !hasSubmissions else { return }

    let chickadeePushed =
        try await APIBrightSpaceSyncLog.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == studentUserID)
        .filter(\.$status == APIBrightSpaceSyncLog.Status.success.rawValue)
        .first() != nil
    guard chickadeePushed else { return }

    let now = Date()
    if let existing = try await APIBrightSpaceGradeClear.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == studentUserID)
        .first()
    {
        existing.brightspaceSyncPending = true
        if existing.brightspacePendingSince == nil { existing.brightspacePendingSince = now }
        existing.brightspaceSyncError = nil
        try await existing.save(on: db)
    } else {
        let row = APIBrightSpaceGradeClear(testSetupID: testSetupID, userID: studentUserID)
        row.brightspacePendingSince = now
        try await row.save(on: db)
    }
}

/// Marks every result on one student's submissions for a test setup as pending
/// BrightSpace sync, so the debounced sweep re-pushes the grade after an
/// override is set or cleared. Call it through `requestGradePush`, which also
/// queues the LTI push.  When the student has NO submissions there is no
/// result row to flag, so the supplied override row carries the pending flag
/// itself — the sweep scans both (see `sweepBrightSpaceGradeSync`).  `override`
/// is nil on the clear path (the row was deleted), in which case a
/// no-submission student is a no-op (nothing to push, nothing to revert).
func flagStudentForBrightSpaceSync(
    override: APIGradeOverride?,
    testSetupID: String,
    studentUserID: UUID,
    on db: any Database
) async throws {
    let now = Date()
    let flagged = try await flagStudentResultsPending(
        testSetupID: testSetupID, studentUserID: studentUserID, since: now, on: db)
    guard flagged else {
        // No submissions: the override row is the only thing to push.
        guard let override else { return }
        override.brightspaceSyncPending = true
        if override.brightspacePendingSince == nil {
            override.brightspacePendingSince = now
        }
        try await override.save(on: db)
        return
    }
}

/// Flags every result on one student's student-submissions for a setup as
/// pending BrightSpace sync, in one statement, keeping each row's
/// `brightspace_pending_since` when it is already set. Returns whether any
/// result was flagged.
private func flagStudentResultsPending(
    testSetupID: String, studentUserID: UUID, since now: Date, on db: any Database
) async throws -> Bool {
    if let sql = db as? (any SQLDatabase) {
        let rows = try await sql.raw(
            """
            UPDATE \(unsafeRaw: APIResult.schema)
            SET brightspace_sync_pending = true,
                brightspace_pending_since = COALESCE(brightspace_pending_since, \(bind: now))
            WHERE submission_id IN (
              SELECT id FROM \(unsafeRaw: APISubmission.schema)
              WHERE user_id = \(bind: studentUserID) AND test_setup_id = \(bind: testSetupID)
                AND kind = \(bind: APISubmission.Kind.student))
            RETURNING id
            """
        ).all()
        return !rows.isEmpty
    }
    let results = try await gradeResultsForStudent(
        testSetupID: testSetupID, studentUserID: studentUserID, on: db)
    for result in results {
        result.brightspaceSyncPending = true
        if result.brightspacePendingSince == nil { result.brightspacePendingSince = now }
        try await result.save(on: db)
    }
    return !results.isEmpty
}

/// Every result on one student's student-submissions for a test setup.
private func gradeResultsForStudent(
    testSetupID: String, studentUserID: UUID, on db: any Database
) async throws -> [APIResult] {
    let submissionIDs = try await APISubmission.query(on: db)
        .filter(\.$userID == studentUserID)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
        .compactMap(\.id)
    guard !submissionIDs.isEmpty else { return [] }
    return try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ submissionIDs)
        .all()
}
