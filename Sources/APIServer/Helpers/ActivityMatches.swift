// APIServer/Helpers/ActivityMatches.swift
//
// The server half of a king-of-the-hill activity (docs/class-activities.md,
// "King of the hill"): choosing a challenger's opponent when its job is
// built, and rewriting the hill when its result lands.
//
// The two halves talk through `match_results`. The claim path OPENS a row
// naming the opponent the job will play; the result path COMPLETES it and
// decides the hill from what the row says the challenger played — never
// from the champion of the moment, which may have changed while the job was
// out. Wired at both ingest paths beside `recordLeaderboardEntry`, for the
// reason that helper records.

import Core
import Fluent
import Foundation
import Vapor

/// The opponent a challenger plays, as the claim path chose it.
struct ChosenOpponent {
    /// The champion's submission, or nil when the bot (or nobody) holds the hill.
    let champion: APISubmission?
    /// `JobOpponent.submissionIdentity` / `supportFileIdentity` / `noOpponentIdentity`.
    let identity: String
}

/// Who a challenger plays right now: the current champion's submission,
/// unless the challenger IS that submission (a re-test of the champion plays
/// the bot, never itself), else the bundled bot, else nobody.
///
/// A champion who RESUBMITS does play their own earlier entry: beating it
/// moves the hill's submission forward, losing to it changes nothing.
func chooseOpponent(
    for submission: APISubmission, activity: ClassActivity, on db: Database
) async throws -> ChosenOpponent {
    let bot = ChosenOpponent(
        champion: nil,
        identity: activity.opponentFile.map(JobOpponent.supportFileIdentity)
            ?? JobOpponent.noOpponentIdentity)
    guard activity.kind.opponentSource == .champion,
        let champion = try await APIActivityChampion.query(on: db)
            .filter(\.$testSetupID == submission.testSetupID)
            .first(),
        champion.submissionID != submission.id,
        let championSubmission = try await APISubmission.find(champion.submissionID, on: db)
    else { return bot }
    return ChosenOpponent(
        champion: championSubmission,
        identity: JobOpponent.submissionIdentity(champion.submissionID))
}

/// Every classmate a round-robin challenger plays: the latest complete
/// submission of every OTHER `.student` enrolled in the setup's course. When
/// there is none yet, the bundled bot stands in (or nobody, when there is no
/// bot either), so the first submitter still has a match and a row.
///
/// Latest by submission time, one per classmate, so a resubmission by B
/// changes what A's NEXT job plays and never what A's landed job played.
func chooseClassmates(
    for submission: APISubmission, activity: ClassActivity, on db: Database
) async throws -> [ChosenOpponent] {
    guard activity.kind.opponentSource == .classmates,
        let setup = try await APITestSetup.find(submission.testSetupID, on: db)
    else { return [] }
    // NULL role is a pre-migration student (the `role` accessor's default).
    let students = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == setup.courseID)
        .group(.or) { or in
            or.filter(\.$roleRaw == CourseRole.student.rawValue)
            or.filter(\.$roleRaw == .null)
        }
        .all()
        .map(\.userID)
        .filter { $0 != submission.userID }
    guard !students.isEmpty else { return [] }
    let candidates = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == submission.testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$status == SubmissionStatus.complete.rawValue)
        .filter(\.$userID ~~ students)
        .sort(\.$submittedAt, .descending)
        .all()
    var latestByUser: [UUID: APISubmission] = [:]
    for candidate in candidates {
        guard let userID = candidate.userID, latestByUser[userID] == nil else { continue }
        latestByUser[userID] = candidate
    }
    // Stable order — by submission ID — so two claims of one submission
    // stage the same opponents in the same order.
    return latestByUser.values
        .sorted { ($0.id ?? "") < ($1.id ?? "") }
        .compactMap { classmate in
            classmate.id.map {
                ChosenOpponent(champion: classmate, identity: JobOpponent.submissionIdentity($0))
            }
        }
}

/// Opens (or reopens, on a re-test) the match row for this job. One row per
/// (submission, opponent identity): a re-test against the same opponent
/// reuses it, so a replayed report of the earlier run can no longer complete
/// a row the re-test owns.
func openMatch(
    testSetupID: String, submissionID: String, opponent: ChosenOpponent, seed: String, on db: Database
) async throws {
    let existing = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$opponentIdentity == opponent.identity)
        .first()
    if let existing {
        existing.score = nil
        existing.metric = nil
        existing.won = nil
        existing.completedAt = nil
        existing.createdAt = Date()
        existing.seed = seed
        try await existing.update(on: db)
    } else {
        // Ignore the conflict: two claims of one submission at once, first
        // insert wins — the same shape as `awardImmutableBadge`.
        try? await APIMatchResult(
            testSetupID: testSetupID, submissionID: submissionID,
            opponentSubmissionID: opponent.champion?.id, opponentIdentity: opponent.identity,
            seed: seed, createdAt: Date()
        ).save(on: db)
    }
}

/// Completes this submission's open match and rewrites the hill.
///
/// The rules, each pinned by `ActivityChampionTests`:
///
/// - A **replayed** report finds no open row and does nothing.
/// - A **re-test of the champion's own submission** never moves the hill,
///   whatever it scores: the row it played was against the bot.
/// - The challenger **takes the hill** when the match entry passed AND the
///   opponent it played is still the hill's holder (the current champion's
///   submission, or the bot / nobody while no student holds it). A win
///   against a champion who has since been replaced crowns nobody: the
///   student beat the wrong opponent, and a re-test plays the right one.
/// - A **champion beating their own earlier entry** moves the hill's
///   submission forward and keeps the streak.
/// - A **loss to the current champion** counts one defence.
/// - Only a `.student` in the setup's own course can hold the hill, so a
///   staff validation run completes its row and changes nothing.
func recordActivityMatch(
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    outcomes: [TestOutcome],
    matches: [MatchReport]? = nil,
    on db: Database
) async throws {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let activity = setup.decodedManifest()?.activity
    else { return }
    switch activity.kind.opponentSource {
    case .none, .supportFile:
        return
    case .classmates:
        try await recordMatrixMatches(
            setup: setup, userID: userID, submissionID: submissionID,
            outcomes: outcomes, matches: matches, on: db)
        return
    case .champion:
        break
    }
    guard
        let match = try await APIMatchResult.query(on: db)
            .filter(\.$submissionID == submissionID)
            .filter(\.$completedAt == nil)
            .sort(\.$createdAt, .descending)
            .first()
    else { return }

    let entry = matchOutcome(from: outcomes)
    let won = entry?.status == .pass
    match.score = entry?.score
    match.metric = entry?.metric
    match.won = won
    match.completedAt = Date()
    try await match.update(on: db)

    guard try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student else { return }
    let current = try await APIActivityChampion.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .first()
    // The champion's own re-test played the bot; the hill does not move.
    if current?.submissionID == submissionID { return }
    // What the job played must still be what holds the hill.
    let playedTheHill = match.opponentSubmissionID == current?.submissionID
    guard playedTheHill else { return }

    if won {
        if let current, current.userID == userID {
            current.submissionID = submissionID
            try await current.update(on: db)
        } else if let current {
            current.userID = userID
            current.submissionID = submissionID
            current.crownedAt = Date()
            current.defences = 0
            try await current.update(on: db)
        } else {
            try? await APIActivityChampion(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, crownedAt: Date()
            ).save(on: db)
        }
        try await awardChampionRecords(setup: setup, userID: userID, submissionID: submissionID, on: db)
    } else if let current, current.userID != userID {
        current.defences += 1
        try await current.update(on: db)
    }
}

// MARK: - Round robin

/// Completes a matrix job's open rows from the worker's per-match reports —
/// by opponent identity, the key the claim opened them under — then
/// recomputes the challenger's standings row and moves the standings-leader
/// record. A job that played the bot alone (no classmate yet) reports no
/// per-match rows; its one open row is completed from the collection's match
/// entry, as a hill match is.
///
/// Only the challenger's row is recomputed: a classmate's standings count
/// only THEIR latest submission's own matches, so a landed result changes
/// nothing about anyone else. That is what makes a resubmission supersede
/// rather than delete — B's row against A's earlier entry stands until B
/// resubmits (docs/class-activities.md).
private func recordMatrixMatches(
    setup: APITestSetup, userID: UUID, submissionID: String,
    outcomes: [TestOutcome], matches: [MatchReport]?, on db: Database
) async throws {
    let open = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$completedAt == nil)
        .all()
    guard !open.isEmpty else { return }  // a replayed report

    var reportByIdentity: [String: MatchReport] = [:]
    for report in matches ?? [] { reportByIdentity[report.opponentIdentity] = report }
    let single = matchOutcome(from: outcomes)
    for row in open {
        if let report = reportByIdentity[row.opponentIdentity] {
            row.score = report.score
            row.metric = report.metric
            row.won = report.won
        } else if matches == nil {
            row.score = single?.score
            row.metric = single?.metric
            row.won = single?.status == .pass
        } else {
            // The worker played a different set than the claim opened — a
            // row it never reported stays open and counts nothing.
            continue
        }
        row.completedAt = Date()
        try await row.update(on: db)
    }

    guard let setupID = setup.id,
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }
    try await recomputeStanding(testSetupID: setupID, userID: userID, submissionID: submissionID, on: db)
    if let leader = try await activityStandings(testSetupID: setupID, on: db).first {
        try await awardTournamentWinnerRecords(
            setup: setup, userID: leader.userID, submissionID: leader.submissionID, on: db)
    }
}

/// Rewrites the student's standings row from `submissionID`'s completed
/// matches. A draw is a completed match the challenger did not win whose
/// score is exactly one half; a loss is any other non-win.
func recomputeStanding(testSetupID: String, userID: UUID, submissionID: String, on db: Database) async throws {
    let rows = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$completedAt != nil)
        .all()
    let wins = rows.filter { $0.won == true }.count
    let draws = rows.filter { $0.won != true && $0.score == 0.5 }.count
    let losses = rows.count - wins - draws
    let scoreSum = rows.compactMap(\.score).reduce(0, +)
    let existing = try await APIActivityStanding.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == userID)
        .first()
    if let existing {
        existing.submissionID = submissionID
        existing.played = rows.count
        existing.wins = wins
        existing.draws = draws
        existing.losses = losses
        existing.scoreSum = scoreSum
        existing.updatedAt = Date()
        try await existing.update(on: db)
    } else {
        try? await APIActivityStanding(
            testSetupID: testSetupID, userID: userID, submissionID: submissionID,
            played: rows.count, wins: wins, draws: draws, losses: losses, scoreSum: scoreSum,
            updatedAt: Date()
        ).save(on: db)
    }
}

/// The standings, best first: average match score, then wins, then matches
/// played, then the earlier row.
func activityStandings(testSetupID: String, on db: Database) async throws -> [APIActivityStanding] {
    try await APIActivityStanding.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .all()
        .sorted { a, b in
            if a.averageScore != b.averageScore { return a.averageScore > b.averageScore }
            if a.wins != b.wins { return a.wins > b.wins }
            if a.played != b.played { return a.played > b.played }
            return (a.updatedAt ?? .distantPast) < (b.updatedAt ?? .distantPast)
        }
}

/// A student's place (1 = first) and win count in the standings, for the
/// `standing` / `matchesWon` badge signals; nil when they have no row.
func standingSignals(
    testSetupID: String, userID: UUID, on db: Database
) async throws -> (standing: Int, matchesWon: Int)? {
    let standings = try await activityStandings(testSetupID: testSetupID, on: db)
    guard let index = standings.firstIndex(where: { $0.userID == userID }) else { return nil }
    return (index + 1, standings[index].wins)
}

/// The hill's current holder, for the leaderboard page; nil when the bot or
/// nobody holds it.
func currentChampion(testSetupID: String, on db: Database) async throws -> APIActivityChampion? {
    try await APIActivityChampion.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .first()
}
