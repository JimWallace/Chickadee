// APIServer/Services/WardrobeUnlockStore.swift
//
// Grants the wardrobe items a student has earned (Core/WardrobeItem.swift,
// #2592) and reads the ones already stored. Grants run when the account page
// or a result page loads, never while a result is written, so a cosmetic
// cannot fail a grade.
// A stored unlock is never taken back.

import Core
import Fluent
import Foundation
import SQLKit

enum WardrobeUnlockStore {

    /// The items `userID` has stored.
    static func unlocked(for userID: UUID, on db: any Database) async throws -> Set<WardrobeItem> {
        let rows = try await APIWardrobeUnlock.query(on: db).filter(\.$userID == userID).all()
        return Set(rows.compactMap { WardrobeItem(rawValue: $0.item) })
    }

    /// The stored achievement name of each item an achievement granted
    /// `userID` (docs/achievement-rewards.md, S2), for the account page's
    /// "how you earned it". A rule item or a found one has no label.
    static func grantLabels(for userID: UUID, on db: any Database) async throws -> [WardrobeItem: String] {
        let rows = try await APIWardrobeUnlock.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$label != nil)
            .all()
        var labels: [WardrobeItem: String] = [:]
        for row in rows {
            guard let item = WardrobeItem(rawValue: row.item), let label = row.label else { continue }
            labels[item] = label
        }
        return labels
    }

    /// What `userID`'s own graded student submissions show.
    static func progress(for userID: UUID, on db: any Database) async throws -> WardrobeProgress {
        WardrobeProgress(graded: try await graded(for: userID, inTestSetups: nil, on: db))
    }

    /// `userID`'s own graded student submissions, as the rules read them:
    /// every one, or only those to the test setups in `testSetupIDs`. The
    /// course achievements read the second form (AchievementAwardStore).
    static func graded(
        for userID: UUID, inTestSetups testSetupIDs: Set<String>?, on db: any Database
    ) async throws -> [WardrobeProgress.Graded] {
        if let testSetupIDs, testSetupIDs.isEmpty { return [] }
        var query = APIResult.query(on: db)
            .join(APISubmission.self, on: \APIResult.$submissionID == \APISubmission.$id)
            .filter(APISubmission.self, \.$userID == userID)
            .filter(APISubmission.self, \.$kind == APISubmission.Kind.student)
        if let testSetupIDs {
            query = query.filter(APISubmission.self, \.$testSetupID ~~ Array(testSetupIDs))
        }
        // Only the columns the rules read: with no setup filter this spans
        // every graded submission the student has made.
        let results =
            try await query
            .field(\.$earnedPoints)
            .field(\.$totalPoints)
            .field(\.$passCount)
            .field(\.$totalTests)
            .field(APISubmission.self, \.$testSetupID)
            .field(APISubmission.self, \.$attemptNumber)
            .field(APISubmission.self, \.$submittedAt)
            .all()
        let submissions = try results.map { try $0.joined(APISubmission.self) }
        let (dueDates, concepts) = try await dueDatesAndConcepts(of: Set(submissions.map(\.testSetupID)), on: db)
        return zip(results, submissions).map { result, submission in
            WardrobeProgress.Graded(
                assignmentID: submission.testSetupID,
                // A row with no attempt number is not counted as a first try.
                attemptNumber: submission.attemptNumber ?? 0,
                passCount: result.passCount ?? 0,
                totalTests: result.totalTests ?? 0,
                // The server's own receipt time, so a student cannot forge it.
                secondsBeforeDue: secondsBeforeDue(submission.submittedAt, dueDates[submission.testSetupID]),
                concept: concepts[submission.testSetupID],
                gradePercent: result.gradePercentValue)
        }
    }

    /// A fingerprint of everything `graded(for:inTestSetups: nil)` reads for
    /// `userID`: the count and the newest receipt time of their graded
    /// student-submission results, and a hash of the due date and concept of
    /// each assignment they submitted to. One aggregate row; nil off SQL,
    /// which grants every time.
    ///
    /// The count and time see every new or deleted result because a result
    /// row is never edited in place: a retest adds a row, and `received_at`
    /// is stamped on create. A path that rewrote a result's grade columns in
    /// place would have to change this fingerprint too.
    static func gradedFingerprint(for userID: UUID, on db: any Database) async throws -> WardrobeGradedFingerprint? {
        guard let sql = db as? (any SQLDatabase) else { return nil }
        struct Row: Decodable {
            let count: Int
            let latest: Date?
            let assignments: String?
        }
        let row = try await sql.raw(
            """
            WITH own AS (
                SELECT s.id, s.test_setup_id
                FROM \(unsafeRaw: APISubmission.schema) s
                WHERE s.user_id = \(bind: userID)
                  AND s.kind = \(bind: APISubmission.Kind.student)
            )
            SELECT
                (SELECT COUNT(*) FROM \(unsafeRaw: APIResult.schema) r
                    INNER JOIN own ON own.id = r.submission_id) AS count,
                (SELECT MAX(r.received_at) FROM \(unsafeRaw: APIResult.schema) r
                    INNER JOIN own ON own.id = r.submission_id) AS latest,
                (SELECT md5(string_agg(
                        a.test_setup_id || ':' || COALESCE(a.due_at::text, '') || ':' || COALESCE(a.concept, ''),
                        ',' ORDER BY a.test_setup_id))
                    FROM \(unsafeRaw: APIAssignment.schema) a
                    WHERE a.test_setup_id IN (SELECT test_setup_id FROM own)) AS assignments
            """
        ).first(decoding: Row.self)
        return row.map {
            WardrobeGradedFingerprint(count: $0.count, latest: $0.latest, assignments: $0.assignments)
        }
    }

    /// The due date and the concept of each test setup's assignment, from
    /// one read of the assignments. A setup whose assignment has no due date
    /// is not in the first map, and one whose assignment has no concept is
    /// not in the second. The early rule reads the assignment's own due date,
    /// not a student's extension.
    private static func dueDatesAndConcepts(
        of testSetupIDs: Set<String>, on db: any Database
    ) async throws -> (dueDates: [String: Date], concepts: [String: AssignmentConcept]) {
        guard !testSetupIDs.isEmpty else { return ([:], [:]) }
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$testSetupID ~~ Array(testSetupIDs))
            .field(\.$testSetupID)
            .field(\.$dueAt)
            .field(\.$conceptRaw)
            .all()
        var dueDates: [String: Date] = [:]
        var concepts: [String: AssignmentConcept] = [:]
        for assignment in assignments {
            if let dueAt = assignment.dueAt { dueDates[assignment.testSetupID] = dueAt }
            if let concept = assignment.concept { concepts[assignment.testSetupID] = concept }
        }
        return (dueDates, concepts)
    }

    private static func secondsBeforeDue(_ submittedAt: Date?, _ dueAt: Date?) -> Double? {
        guard let submittedAt, let dueAt else { return nil }
        return dueAt.timeIntervalSince(submittedAt)
    }

    /// Stores every item `userID` has earned and not yet stored, and returns
    /// what is stored afterwards, so the page offers exactly what the save
    /// route accepts. A failed write keeps the page, with a warning in the
    /// log: the next load grants again. The unique index stores an item once
    /// when two requests race, and that conflict is not logged (#2776).
    static func grantEarned(for userID: UUID, on db: any Database) async throws -> Set<WardrobeItem> {
        try await grantEarned(for: userID, stored: try await unlocked(for: userID, on: db), on: db).stored
    }

    /// `grantEarned` from the items `userID` has stored, already read. Also
    /// says whether every earned item is stored afterwards, which is false
    /// when a write failed.
    private static func grantEarned(
        for userID: UUID, stored: Set<WardrobeItem>, on db: any Database
    ) async throws -> (stored: Set<WardrobeItem>, complete: Bool) {
        // A found item and a grantable one are never earned by a rule, so a
        // student who has earned every rule item skips the progress queries,
        // whatever else they hold.
        guard !stored.isSuperset(of: WardrobeItem.allCases.filter(\.hasBuiltInRule)) else { return (stored, true) }
        let earned = WardrobeItem.earned(by: try await progress(for: userID, on: db))
        let missing = earned.subtracting(stored)
        guard !missing.isEmpty else { return (stored, true) }
        for item in WardrobeItem.allCases where missing.contains(item) {
            do {
                try await APIWardrobeUnlock(userID: userID, item: item).createIgnoringConflict(on: db)
            } catch {
                // The user id goes in metadata only (compliance audit F-1).
                db.logger.warning(
                    "Wardrobe unlock of \(item.rawValue) not stored: \(error)",
                    metadata: ["user_id": .string(userID.uuidString)])
            }
        }
        let after = try await unlocked(for: userID, on: db)
        return (after, after.isSuperset(of: earned))
    }

    /// Stores the found item `item` for `userID` (docs/student-wardrobe.md,
    /// "Found items"). Returns true when this call stored it, and false when
    /// it was already stored, so the page tells a student once. Refuses an
    /// earned item: only graded work grants one of those.
    static func grantFound(
        _ item: WardrobeItem, for userID: UUID, on db: any Database
    ) async throws -> Bool {
        guard item.isFound else {
            throw AppError.invalidParameter(name: "item", reason: "\(item.rawValue) is earned, not found.")
        }
        guard try await !unlocked(for: userID, on: db).contains(item) else { return false }
        do {
            try await APIWardrobeUnlock(userID: userID, item: item).save(on: db)
            return true
        } catch {
            // The unique index stores the item once when two requests race:
            // the loser's write fails, and the item is stored all the same.
            // Any other failure is a real one.
            guard try await unlocked(for: userID, on: db).contains(item) else { throw error }
            return false
        }
    }

    /// Grants as `grantEarned` does, and returns only the items that this
    /// call stored, in wardrobe order. The result page's Earned toast shows
    /// these, so each item shows once, because a grant happens once
    /// (docs/result-celebration.md, J2). When two pages load at once, one
    /// may store the item and the other show it, or neither show it: the
    /// item is still stored, and the account page offers it.
    ///
    /// The page loads far more often than a result arrives, so `checks` skips
    /// the grant while the student's results are unchanged since the last
    /// complete grant (`WardrobeGrantChecks`).
    static func grantNew(
        for userID: UUID, on db: any Database, checks: WardrobeGrantChecks
    ) async throws -> [WardrobeItem] {
        let fingerprint = try await gradedFingerprint(for: userID, on: db)
        if let fingerprint, await checks.isUnchanged(userID, fingerprint) { return [] }
        let stored = try await unlocked(for: userID, on: db)
        let outcome = try await grantEarned(for: userID, stored: stored, on: db)
        if let fingerprint, outcome.complete { await checks.recordComplete(userID, fingerprint) }
        let granted = outcome.stored.subtracting(stored)
        // A found item or a granted one stored by a concurrent request is not
        // this grant's to show: its own toast said so.
        return WardrobeItem.allCases.filter { granted.contains($0) && $0.hasBuiltInRule }
    }
}
