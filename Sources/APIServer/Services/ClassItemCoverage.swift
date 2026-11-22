// APIServer/Services/ClassItemCoverage.swift
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
import SQLKit
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
///
/// Takes the loaded setup: the result path reads it once for every effect.
func recordClassItemCoverage(
    setup: APITestSetup,
    userID: UUID,
    submissionID: String,
    outcomes: [TestOutcome],
    declaredSlotCount: Int,
    on db: any Database
) async throws {
    guard declaredSlotCount > 0, let testSetupID = setup.id else { return }
    let covered = outcomes.filter { $0.status == .pass }.map(\.testName)
    guard !covered.isEmpty else { return }

    guard try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }

    // On an activity that runs per lab group, the items count for the lab of
    // the session the student submitted in, and with no such session for
    // nobody (docs/lab-groups.md, slice 5b).
    if setup.decodedManifest()?.activity?.isPerGroup == true {
        guard
            let session = try await ActivitySessionStore.sessionAtSubmission(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
        else { return }
        try await recordLabItemCoverage(
            testSetupID: testSetupID, groupID: session.groupID, items: covered, userID: userID,
            submissionID: submissionID, on: db)
        return
    }

    // One statement for the whole submission rather than one per item: a
    // suite can carry dozens of variants and this runs on the result path.
    // The first submission to cover an item keeps it: the unique
    // `(test_setup_id, item)` turns every later insert into nothing.
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The class coverage write needs a SQL database.")
    }
    try await CoverageInsert(
        testSetupID: testSetupID, groupID: nil, items: covered, userID: userID, submissionID: submissionID
    ).run(into: APIClassItemCoverage.schema, keyColumns: ["test_setup_id", "item"], on: sql)
}

/// One submission's covered items, written as coverage rows. `groupID` is
/// set only for the per-lab table.
private struct CoverageInsert {
    let testSetupID: String
    let groupID: UUID?
    let items: [String]
    let userID: UUID
    let submissionID: String

    /// Inserts one row per distinct item in one statement, and skips the items
    /// that a row already holds (`ON CONFLICT DO NOTHING` on `keyColumns`, the
    /// table's unique key).
    func run(into table: String, keyColumns: [String], on sql: any SQLDatabase) async throws {
        var distinct: [String] = []
        var seen: Set<String> = []
        for item in items where seen.insert(item).inserted { distinct.append(item) }
        guard !distinct.isEmpty else { return }

        let now = Date()
        var columns = ["id", "test_setup_id", "item", "user_id", "submission_id", "covered_at"]
        if groupID != nil { columns.insert("group_id", at: 2) }
        var insert = sql.insert(into: table).columns(columns)
        for item in distinct {
            var row: [any SQLExpression] = [SQLBind(UUID()), SQLBind(testSetupID)]
            if let groupID { row.append(SQLBind(groupID)) }
            row += [SQLBind(item), SQLBind(userID), SQLBind(submissionID), SQLBind(now)]
            insert = insert.values(row)
        }
        try await insert.ignoringConflicts(with: keyColumns).run()
    }
}

/// The class's coverage of one assignment: how many distinct items have been
/// covered, and by whom.
///
/// Reads the materialised union rather than the stored collections, which is
/// the whole point of materialising it.
func classItemCoverage(
    testSetupID: String, on db: any Database
) async throws -> [APIClassItemCoverage] {
    try await APIClassItemCoverage.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .sort(\.$item)
        .all()
}

/// One covered item and the student who covered it first: a row of the
/// class's coverage or of a lab's.
struct CoveredItem: Equatable, Sendable {
    let item: String
    let userID: UUID
}

/// Records `items` as covered by one lab group (docs/lab-groups.md, slice
/// 5b), with the rules of the class's union above: the first submission to
/// cover an item in the lab keeps it, and a replay inserts nothing.
func recordLabItemCoverage(
    testSetupID: String, groupID: UUID, items: [String], userID: UUID, submissionID: String,
    on db: any Database
) async throws {
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The lab coverage write needs a SQL database.")
    }
    try await CoverageInsert(
        testSetupID: testSetupID, groupID: groupID, items: items, userID: userID, submissionID: submissionID
    ).run(into: APIGroupClassItemCoverage.schema, keyColumns: ["test_setup_id", "group_id", "item"], on: sql)
}

/// Every lab's coverage of one assignment, by lab.
func labItemCoverage(testSetupID: String, on db: any Database) async throws -> [UUID: [CoveredItem]] {
    let rows = try await APIGroupClassItemCoverage.query(on: db).filter(\.$testSetupID == testSetupID).all()
    return Dictionary(grouping: rows, by: \.groupID).mapValues { rows in
        rows.map { CoveredItem(item: $0.item, userID: $0.userID) }
    }
}

/// How many contribution slots the assignment behind `setup` declares, or
/// 0 when it declares none / has no starter notebook.
///
/// Shared by both result-ingest paths so the gate cannot be applied on one and
/// forgotten on the other — the audit-A2 shape. Reads through
/// `notebookBytesCache` (#1171) rather than unzipping per result, so a deadline
/// spike of submissions shares one notebook resolution. The cache also keeps
/// the count beside the bytes, and remembers a setup with no notebook, so a
/// result neither parses the notebook again nor lists the zip again.
///
/// Best-effort by construction: any failure to resolve the notebook yields 0,
/// which means "not a contribution assignment" and skips accumulation. That is
/// the safe direction — a missed row is recoverable by re-testing, whereas
/// failing a student's result report to record a diagnostic is not.
func declaredContributionSlotCount(setup: APITestSetup, app: Application) async -> Int {
    await app.notebookBytesCache.declaredContributionSlotCount(for: NotebookSourceRef(setup))
}
