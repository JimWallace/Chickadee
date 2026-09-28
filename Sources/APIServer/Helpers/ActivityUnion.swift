// APIServer/Helpers/ActivityUnion.swift
//
// The union reading of a matrix activity (docs/class-activities.md, "Tests
// and code"): the same `match_results` rows read TWICE, once as what each
// student's tests defeated and once as how each student's own code held up.
//
// MATERIALISES NOTHING. Every other aggregation writes a row at ingest —
// `leaderboard_entries`, `activity_standings`, `tournament_runs` — because
// each answers a question the stored outcomes cannot answer cheaply. This
// one can: a union over matches is a query over the rows the matrix already
// completed, which is what `docs/collaborative-class-assignments.md` says a
// bug-set union is. Storing it would mean storing one number that answers
// only the tester's half, and that half reads as the whole record.
//
// THE TWO HALVES SCOPE DIFFERENTLY, deliberately, and it is the same
// asymmetry `class_item_coverage` already carries between coverage and
// breadth. A KILL belongs to the student whose test found the fault and
// stays theirs even after the author fixes it — their work is not undone by
// somebody else's later submission. A DEFENCE belongs to the author's
// CURRENT submission only, because the question it answers is whether the
// code that stands today has held up.
//
// Nothing here reaches a grade. A union kind feeds achievements only, and
// `isSweepEvaluableClassGoal` admits no shape that reads these rows, so a
// number that moves when a student resubmits can never freeze into a grade
// push — which is why this one may move at all, where a coverage count must
// never retreat.

import Core
import Fluent
import Foundation
import Vapor

/// One student's record as a tester: the classmates whose code their latest
/// submission's tests defeated.
struct UnionKillTally: Equatable {
    let userID: UUID
    let submissionID: String
    /// Distinct classmates whose code this student's tests defeated.
    let defeated: Int
    /// Distinct classmates their tests ran against at all.
    let faced: Int
}

/// One student's record as an author: how their CURRENT submission held up.
struct UnionDefenceTally: Equatable {
    let userID: UUID
    let submissionID: String
    /// Distinct classmates whose tests have run against this submission.
    let faced: Int
    /// True once any classmate's test defeated it.
    let defeated: Bool
    /// The first classmate to defeat it; nil while it stands.
    let defeatedByUserID: UUID?
}

/// Both halves of a union activity's reading, each best-first.
struct UnionTally {
    /// Testers, most classmates defeated first.
    let kills: [UnionKillTally]
    /// Authors, code that has held up longest first.
    let defences: [UnionDefenceTally]
    /// How many students' current code has been defeated.
    let defeatedCount: Int
    /// How many students have current code to defeat — the denominator.
    let targetCount: Int
}

/// Reads both halves for one assignment.
///
/// Four queries regardless of class size: the roster's latest submissions,
/// every student submission of the setup (to attribute a kill whose target
/// has since resubmitted), and the completed match rows.
func unionTally(setup: APITestSetup, on db: Database) async throws -> UnionTally {
    guard let setupID = setup.id else {
        return UnionTally(kills: [], defences: [], defeatedCount: 0, targetCount: 0)
    }
    let latestByUser = try await latestStudentSubmissionsByUser(setup: setup, on: db)
    var userByLatestSubmission: [String: UUID] = [:]
    for (userID, submission) in latestByUser {
        if let id = submission.id { userByLatestSubmission[id] = userID }
    }

    // Every student submission, not only the current ones: a kill keeps its
    // target's identity after that student resubmits.
    var userBySubmission: [String: UUID] = [:]
    let allSubmissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
    for submission in allSubmissions {
        if let id = submission.id, let userID = submission.userID { userBySubmission[id] = userID }
    }

    let rows = try await APIMatchResult.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$completedAt != nil)
        .sort(\.$completedAt, .ascending)
        .all()

    var defeatedByTester: [UUID: Set<UUID>] = [:]
    var facedByTester: [UUID: Set<UUID>] = [:]
    var facedByAuthor: [UUID: Set<UUID>] = [:]
    var firstDefeaterByAuthor: [UUID: UUID] = [:]

    for row in rows {
        guard let targetSubmission = row.opponentSubmissionID,
            let testerID = userByLatestSubmission[row.submissionID],
            let targetID = userBySubmission[targetSubmission],
            testerID != targetID
        else { continue }

        // The tester's half counts their current submission's matches,
        // whatever the target has done since.
        facedByTester[testerID, default: []].insert(targetID)
        if row.won == true { defeatedByTester[testerID, default: []].insert(targetID) }

        // The author's half counts only matches against the code that
        // stands today.
        guard latestByUser[targetID]?.id == targetSubmission else { continue }
        facedByAuthor[targetID, default: []].insert(testerID)
        if row.won == true, firstDefeaterByAuthor[targetID] == nil {
            firstDefeaterByAuthor[targetID] = testerID
        }
    }

    let kills =
        latestByUser
        .compactMap { userID, submission -> UnionKillTally? in
            guard let submissionID = submission.id else { return nil }
            return UnionKillTally(
                userID: userID, submissionID: submissionID,
                defeated: defeatedByTester[userID]?.count ?? 0,
                faced: facedByTester[userID]?.count ?? 0)
        }
        .sorted { a, b in
            if a.defeated != b.defeated { return a.defeated > b.defeated }
            if a.faced != b.faced { return a.faced > b.faced }
            return a.submissionID < b.submissionID
        }

    let defences =
        latestByUser
        .compactMap { userID, submission -> UnionDefenceTally? in
            guard let submissionID = submission.id else { return nil }
            return UnionDefenceTally(
                userID: userID, submissionID: submissionID,
                faced: facedByAuthor[userID]?.count ?? 0,
                defeated: firstDefeaterByAuthor[userID] != nil,
                defeatedByUserID: firstDefeaterByAuthor[userID])
        }
        .sorted { a, b in
            // Code that has held up, most tests faced first; then the code
            // that fell, least recently tested last.
            if a.defeated != b.defeated { return !a.defeated }
            if a.faced != b.faced { return a.faced > b.faced }
            return a.submissionID < b.submissionID
        }

    return UnionTally(
        kills: kills,
        defences: defences,
        defeatedCount: defences.filter(\.defeated).count,
        targetCount: defences.count)
}
