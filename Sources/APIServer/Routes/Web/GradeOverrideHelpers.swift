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
