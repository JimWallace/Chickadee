// APIServer/Routes/Web/GradeOverrideHelpers.swift
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
    setupIDs: some Collection<String>, on db: Database
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
    setupID: String, userID: UUID, on db: Database
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
    guard let props = setup.decodedManifest() else { return nil }
    let total = props.testSuites.map(\.points).reduce(0, +)
    guard total > 0 else { return nil }
    return Double(percent) / 100.0 * Double(total)
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
    on db: Database
) async throws {
    let row =
        try await APIGradeOverride.query(on: db)
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
    try await row.save(on: db)
    try await flagOverrideOrResultsPendingSync(
        override: row, testSetupID: testSetupID, studentUserID: studentUserID, on: db)
}

/// Clears any (setup, user) override and re-flags the student's results for
/// BrightSpace sync so the next sweep reverts to the runner-computed grade.
/// Returns `true` when a row existed and was removed (the caller uses this to
/// gate the audit-log entry).
@discardableResult
func clearGradeOverride(
    testSetupID: String,
    studentUserID: UUID,
    on db: Database
) async throws -> Bool {
    guard
        let existing = try await APIGradeOverride.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$userID == studentUserID)
            .first()
    else {
        return false
    }
    try await existing.delete(on: db)
    // Clearing reverts to the runner-computed grade. For a student with
    // submissions that re-flags their results; for a no-submission student
    // there's nothing to push (override is nil → no-op), so the previously
    // pushed grade is left as-is in BrightSpace.
    try await flagOverrideOrResultsPendingSync(
        override: nil, testSetupID: testSetupID, studentUserID: studentUserID, on: db)
    return true
}

/// Marks every result on one student's submissions for a test setup as pending
/// BrightSpace sync, so the debounced sweep re-pushes the grade after an
/// override is set or cleared.  When the student has NO submissions there is no
/// result row to flag, so the supplied override row carries the pending flag
/// itself — the sweep scans both (see `sweepBrightSpaceGradeSync`).  `override`
/// is nil on the clear path (the row was deleted), in which case a
/// no-submission student is a no-op (nothing to push, nothing to revert).
func flagOverrideOrResultsPendingSync(
    override: APIGradeOverride?,
    testSetupID: String,
    studentUserID: UUID,
    on db: Database
) async throws {
    let now = Date()
    let results = try await gradeResultsForStudent(
        testSetupID: testSetupID, studentUserID: studentUserID, on: db)
    guard !results.isEmpty else {
        // No submissions: the override row is the only thing to push.
        guard let override else { return }
        override.brightspaceSyncPending = true
        if override.brightspacePendingSince == nil {
            override.brightspacePendingSince = now
        }
        try await override.save(on: db)
        return
    }
    for result in results {
        result.brightspaceSyncPending = true
        if result.brightspacePendingSince == nil {
            result.brightspacePendingSince = now
        }
        try await result.save(on: db)
    }
}

/// Every result on one student's student-submissions for a test setup.
private func gradeResultsForStudent(
    testSetupID: String, studentUserID: UUID, on db: Database
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
