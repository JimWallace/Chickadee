// APIServer/Services/BrightSpaceGradeSelection.swift
//
// Pure grade selection for BrightSpace sync: which grade a student's results
// (or instructor override) yield for a test setup, and how that grade scales
// onto the D2L grade item's own maximum.  No sweep orchestration or sync-flag
// bookkeeping lives here — see BrightSpaceSyncSweep.swift and
// BrightSpaceGradeSyncService.swift.

import Fluent
import Foundation
import Vapor

/// One student's best grade for a test setup: the raw points Chickadee would
/// push (in suite-point units) plus the denominator (suite total) used to
/// derive them, so the caller can rescale to the BrightSpace grade item's own
/// max. `total` is nil only when neither the manifest nor any result records a
/// total.
struct StudentGrade {
    let points: Double
    let total: Double?
}

/// Best (max) grade for this student across all results for the test setup,
/// preferring worker results over browser ones.  Returns nil when the student
/// has no submissions yet (nothing to push); throws `.missingPoints` when
/// submissions exist but none yielded a parseable grade.
func bestGradeForStudent(
    userID: UUID,
    testSetupID: String,
    db: Database
) async throws -> StudentGrade? {
    // An instructor override replaces the runner-derived grade. It stores a
    // percent, so it needs a points denominator: the suite's total possible
    // points.
    let override = try await APIGradeOverride.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == userID)
        .first()

    let submissionIDs = try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
        .compactMap(\.id)

    // One setup fetch + manifest decode serves both the denominator and the
    // class-goal bonus below (#1128 — each used to re-fetch independently).
    let setupProps = try await APITestSetup.find(testSetupID, on: db)?.decodedManifest()
    let manifestTotal = suiteTotalPoints(props: setupProps)

    guard !submissionIDs.isEmpty else {
        // No submissions yet. Only an override gives us anything to push.
        guard let override else { return nil }
        guard let total = manifestTotal else { return nil }
        return StudentGrade(points: Double(override.overridePercent) / 100.0 * total, total: total)
    }

    if let override {
        let total: Double?
        if let mt = manifestTotal {
            total = mt
        } else {
            total = try await gradeSummariesBySubmissionID(for: submissionIDs, on: db)
                .values.joined()
                .compactMap { $0.gradeTotalPointsValue }.max()
        }
        guard let total, total > 0 else { throw BrightSpaceSyncError.missingPoints }
        return StudentGrade(points: Double(override.overridePercent) / 100.0 * total, total: total)
    }

    // Highest grade wins across ALL result sources (browser + worker alike): a
    // 100 % browser result is never displaced by a later lower worker re-grade,
    // matching the grades CSV / dashboard / roster surfaces.  The shared
    // `bestGradeResult` fold (#1111) returns the winning ROW so the push uses
    // its EXACT points — the Int percent the display surfaces use is lossy
    // for a points push (e.g. 6/7 → 86 % → 8.6 instead of 8.57).
    // Blob-free (#1157): the fold only reads the denormalized grade values.
    let allResults = Array(
        try await gradeSummariesBySubmissionID(for: submissionIDs, on: db).values.joined())
    guard
        let best = bestGradeResult(of: allResults),
        let earned = best.gradePointsValue
    else {
        throw BrightSpaceSyncError.missingPoints
    }
    // Denominator: prefer the manifest's suite total (stable, matches the grades
    // CSV); fall back to the winning result's own recorded total when the
    // manifest carries no per-suite points (mirrors the override branch above and
    // the pre-#1085 behaviour).
    let resultTotal = best.gradeTotalPointsValue
    guard let total = manifestTotal ?? resultTotal, total > 0 else {
        throw BrightSpaceSyncError.missingPoints
    }
    // Express the winning result's grade on the chosen denominator.  When the
    // result carries its own total, scale exactly (earned / resultTotal * total)
    // so integer-percent rounding never enters the pushed value; otherwise the
    // earned value is already in suite-point units (the pass-count fallback).
    let basePoints: Double
    if let resultTotal, resultTotal > 0 {
        basePoints = earned / resultTotal * total
    } else {
        basePoints = earned
    }
    // Class-goal bonus: true extra credit, which may exceed the suite total.
    let bonus = try await classGoalBonusPoints(testSetupID: testSetupID, props: setupProps, on: db)
    let points = earnedWithClassGoalBonus(earned: basePoints, total: total, bonus: bonus)
    return StudentGrade(points: points, total: total)
}

/// One resolved grade push: the points to send, the item they target, a
/// `refusal` when the item can't be synced to at all, and a `warning` recorded
/// alongside a push that goes through but may not land as sent.
struct ScaledGradePush {
    let pushPoints: Double
    let gradeObject: BrightSpaceGradeObject?
    let refusal: String?
    let warning: String?
}

/// The points to push and the grade item they target, or a `refusal` message
/// when the item can't be synced to (non-numeric). Fetches the grade item once
/// (cached) and scales the grade onto its max; a fetch failure degrades to "no
/// scaling, no type check" so a push that would otherwise work isn't blocked.
func scaledGradePush(
    grade: StudentGrade,
    orgUnitID: String,
    gradeObjectID: String,
    client: any BrightSpaceGrading,
    gradeObjectCache: GradeObjectInfoCache,
    application: Application
) async -> ScaledGradePush {
    var gradeObject: BrightSpaceGradeObject?
    do {
        gradeObject = try await gradeObjectCache.info(
            orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, client: client, application: application)
    } catch {
        application.logger.warning("BrightSpace grade-object fetch failed for \(gradeObjectID): \(error)")
    }

    // Refuse a non-numeric / category item with a clear message rather than a
    // bare D2L 400 — Chickadee only writes point values to Numeric items.
    if let type = gradeObject?.gradeType, !type.isEmpty,
        type.caseInsensitiveCompare("Numeric") != .orderedSame
    {
        let message =
            "Grade item '\(gradeObject?.name ?? gradeObjectID)' is type \(type); "
            + "Chickadee can only sync to Numeric grade items."
        return ScaledGradePush(
            pushPoints: grade.points, gradeObject: gradeObject, refusal: message, warning: nil)
    }

    // Scale Chickadee's grade onto the D2L item's own max when both totals are
    // known (e.g. a /14 suite into a /10 LEARN item). When the item's max is
    // unknown or already equals the suite total, this is the identity, so the
    // pushed value is unchanged. The result is rounded to 2 decimals so the
    // gradebook shows a clean value (8.57) rather than 8.571428571…
    var pushPoints = roundedGradePoints(grade.points)
    if let total = grade.total, total > 0, let maxPoints = gradeObject?.maxPoints, maxPoints > 0 {
        pushPoints = roundedGradePoints(grade.points / total * maxPoints)
    }
    return ScaledGradePush(
        pushPoints: pushPoints, gradeObject: gradeObject, refusal: nil,
        warning: aboveMaxWarning(pushPoints: pushPoints, gradeObject: gradeObject))
}

/// Flags a push that exceeds the item's maximum on an item D2L says cannot
/// exceed it. A class-goal bonus is true extra credit, so this is now reachable
/// by design — and it is the one way the bonus can be computed correctly and
/// still not appear in LEARN, since D2L may clamp or reject the value. Recorded
/// on the successful sync-log row rather than refused: a clamped grade is worth
/// more to the student than no grade, and the instructor's fix (tick "Can
/// Exceed" on the item) needs the observation, not a blocked push.
///
/// `canExceed` nil means D2L didn't tell us — say nothing rather than warn on
/// every push to an item whose flag we never captured.
private func aboveMaxWarning(pushPoints: Double, gradeObject: BrightSpaceGradeObject?) -> String? {
    guard let gradeObject,
        let maxPoints = gradeObject.maxPoints, maxPoints > 0,
        pushPoints > maxPoints,
        gradeObject.canExceed == false
    else { return nil }
    return """
        Pushed \(pushPoints) to '\(gradeObject.name)', above its maximum of \(maxPoints). \
        The item is not set to allow grades above the maximum, so LEARN may clamp or reject \
        the extra credit — tick "Can Exceed" on the grade item to keep it.
        """
}

/// Rounds a grade value to 2 decimal places for the LEARN gradebook.
private func roundedGradePoints(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}
