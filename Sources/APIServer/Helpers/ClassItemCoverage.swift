// APIServer/Helpers/ClassItemCoverage.swift
//
// Accumulates the class-wide union of covered items, one row per item,
// attributed to the submission that covered it first. Called from every result
// ingest path — the worker report and the browser result routes — beside the
// class-badge award.
//
// Wired at BOTH paths deliberately. The class-record badges were once awarded
// only in the worker handler, so browser-graded assignments never awarded any
// record until audit A2 caught it; the comment recording that sits at the
// browser call site. A half-wired accumulator is worse than none, because its
// number reads as the whole class when it is only the half that happened to be
// graded on one substrate.

import Core
import Fluent
import Foundation
import Vapor

/// Records every item this submission covered that no earlier submission had.
///
/// Safe to call repeatedly for the same submission: the unique constraint on
/// (test_setup_id, item) means a re-test or a replayed report re-inserts
/// nothing, and the original finder keeps the attribution.
///
/// Deliberately NOT gated on the submission's overall grade. A class goal over
/// the union asks which items the class covered, not which students cleared a
/// threshold — a student who finds one rare bug and nothing else has still
/// contributed that bug.
///
/// Roster-scoped for the same reason the class-goal sweep's numerator is (audit
/// A7): a staff test submission or a dropped student must not inflate a number
/// that carries bonus points to the LMS. Student-ness is per-course, checked
/// against the setup's own course.
///
/// Scoped to CONTRIBUTION assignments by `declaredSlotCount`, which the caller
/// resolves from the instructor's starter notebook. Recording for every
/// assignment was the first shape of this and it was wrong in a way that only
/// showed up one slice later: a union nobody reads is a row per passing test
/// per assignment forever, and it leaves the instructor view with no cheap way
/// to tell a bug hunt from an ordinary lab. Gating here means the mere
/// EXISTENCE of coverage rows answers that question, so the view needs no
/// second signal.
func recordClassItemCoverage(
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    outcomes: [TestOutcome],
    declaredSlotCount: Int,
    on db: Database
) async throws {
    guard declaredSlotCount > 0 else { return }
    let covered = outcomes.filter { $0.status == .pass }.map(\.testName)
    guard !covered.isEmpty else { return }

    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }

    // One query for the whole submission rather than one per item: a suite can
    // carry dozens of variants and this runs on the result path.
    let alreadyCovered = try await APIClassItemCoverage.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$item ~~ covered)
        .all()
    let seen = Set(alreadyCovered.map(\.item))

    for item in covered where !seen.contains(item) {
        let row = APIClassItemCoverage(
            testSetupID: testSetupID, item: item,
            userID: userID, submissionID: submissionID)
        // Ignore the conflict: two submissions covering the same item at once,
        // first insert wins. Same shape as `awardImmutableBadge`.
        try? await row.save(on: db)
    }
}

/// The class's coverage of one assignment: how many distinct items have been
/// covered, and by whom.
///
/// Reads the materialised union rather than the stored collections, which is
/// the whole point of materialising it.
func classItemCoverage(
    testSetupID: String, on db: Database
) async throws -> [APIClassItemCoverage] {
    try await APIClassItemCoverage.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .sort(\.$item)
        .all()
}

/// How many contribution slots the assignment behind `testSetupID` declares, or
/// 0 when it declares none / has no starter notebook.
///
/// Shared by both result-ingest paths so the gate cannot be applied on one and
/// forgotten on the other — the audit-A2 shape. Reads through
/// `notebookBytesCache` (#1171) rather than unzipping per result, so a deadline
/// spike of submissions shares one notebook resolution.
///
/// Best-effort by construction: any failure to resolve the notebook yields 0,
/// which means "not a contribution assignment" and skips accumulation. That is
/// the safe direction — a missed row is recoverable by re-testing, whereas
/// failing a student's result report to record a diagnostic is not.
func declaredContributionSlotCount(
    testSetupID: String, app: Application, on db: Database
) async -> Int {
    guard let setup = try? await APITestSetup.find(testSetupID, on: db),
        let data = try? await app.notebookBytesCache.notebookData(for: NotebookSourceRef(setup))
    else { return 0 }
    return NotebookContributionSlots.declaredSlotCount(inInstructorNotebook: data)
}
