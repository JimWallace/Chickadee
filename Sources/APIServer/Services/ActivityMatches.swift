// APIServer/Services/ActivityMatches.swift
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
import SQLKit
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
/// the bot, never itself), else the bundled bot, else nobody. For an
/// activity that runs per group, the champion is the hill's of the group the
/// student submitted in (`Hill.of`).
///
/// A champion who RESUBMITS does play their own earlier entry: beating it
/// moves the hill's submission forward, losing to it changes nothing.
func chooseOpponent(
    for submission: APISubmission, activity: ClassActivity, on db: any Database
) async throws -> ChosenOpponent {
    let bot = ChosenOpponent(
        champion: nil,
        identity: activity.opponentFile.map(JobOpponent.supportFileIdentity)
            ?? JobOpponent.noOpponentIdentity)
    guard activity.kind.opponentSource == .champion, let submissionID = submission.id,
        let hill = try await Hill.of(
            submissionID: submissionID, testSetupID: submission.testSetupID, userID: submission.userID,
            activity: activity, on: db),
        let champion = try await hill.holder(on: db),
        champion.submissionID != submissionID,
        let championSubmission = try await APISubmission.find(champion.submissionID, on: db)
    else { return bot }
    return ChosenOpponent(
        champion: championSubmission,
        identity: JobOpponent.submissionIdentity(champion.submissionID))
}

/// The latest complete student submission of every enrolled `.student` in
/// the setup's course, keyed by student.
///
/// One definition of "latest", shared by the classmate chooser (who a job
/// plays) and the union read model (whose record counts), so the two cannot
/// disagree about which submission represents a student.
func latestStudentSubmissionsByUser(
    setup: APITestSetup, excluding excluded: UUID? = nil, on db: any Database
) async throws -> [UUID: APISubmission] {
    guard let setupID = setup.id else { return [:] }
    var studentSet = try await CourseRoster.studentIDs(in: setup.courseID, on: db)
    if let excluded { studentSet.remove(excluded) }
    let students = Array(studentSet)
    guard !students.isEmpty else { return [:] }
    let candidates = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
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
    return latestByUser
}

/// Every classmate a round-robin challenger plays: the latest complete
/// submission of every OTHER `.student` enrolled in the setup's course. When
/// there is none yet, the bundled bot stands in (or nobody, when there is no
/// bot either), so the first submitter still has a match and a row.
///
/// Latest by submission time, one per classmate, so a resubmission by B
/// changes what A's NEXT job plays and never what A's landed job played.
///
/// For an activity that runs per lab group, the classmates are the students
/// in the session the challenger submitted in (docs/lab-groups.md, slice
/// 3c); a submission made with no session open plays only the bot.
func chooseClassmates(
    for submission: APISubmission, activity: ClassActivity, on db: any Database
) async throws -> [ChosenOpponent] {
    guard activity.kind.opponentSource == .classmates,
        let setup = try await APITestSetup.find(submission.testSetupID, on: db)
    else { return [] }
    var latestByUser = try await latestStudentSubmissionsByUser(
        setup: setup, excluding: submission.userID, on: db)
    if activity.isPerGroup {
        guard let players = try await sessionPlayers(of: submission, on: db) else { return [] }
        latestByUser = latestByUser.filter { players.contains($0.key) }
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

/// The students who play in the session `submission` was made in: its
/// current run, removed students left out. Nil when the submission was made
/// with no session open.
private func sessionPlayers(of submission: APISubmission, on db: any Database) async throws -> Set<UUID>? {
    guard let userID = submission.userID, let submissionID = submission.id,
        let session = try await ActivitySessionStore.sessionAtSubmission(
            testSetupID: submission.testSetupID, userID: userID, submissionID: submissionID, on: db)
    else { return nil }
    return Set(
        try await ActivitySessionStore.attendance(of: session, on: db).filter { $0.removedAt == nil }.map(\.userID))
}

/// Opens (or reopens, on a re-test) the match row for this job. One row per
/// (submission, opponent identity): a re-test against the same opponent
/// reuses it, so a replayed report of the earlier run can no longer complete
/// a row the re-test owns.
func openMatch(
    testSetupID: String, submissionID: String, opponent: ChosenOpponent, seed: String, round: Int? = nil,
    on db: any Database
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
        existing.round = round
        try await existing.update(on: db)
    } else {
        // Ignore the conflict: two claims of one submission at once, first
        // insert wins — the same shape as `awardImmutableBadge`.
        let row = APIMatchResult(
            testSetupID: testSetupID, submissionID: submissionID,
            opponentSubmissionID: opponent.champion?.id, opponentIdentity: opponent.identity,
            seed: seed, createdAt: Date())
        row.round = round
        try? await row.save(on: db)
    }
}

/// Voids a submission's completed matrix rows before a re-claim opens the
/// current set (#1744). A retest keeps the submission ID, and a classmate
/// who resubmitted since is chosen under a new identity, so the old row
/// against their earlier entry stayed completed beside the new one and
/// `recomputeStanding` counted both. A re-claim replaces the result
/// wholesale; the rows it opens are the only ones that count.
///
/// The claim calls this for a `standings` kind only. A `union` kind keeps
/// its completed rows, because a kill belongs to the tester after the target
/// resubmits (#2187).
func voidCompletedMatrixRows(submissionID: String, on db: any Database) async throws {
    try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$completedAt != nil)
        .delete()
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
    on db: any Database
) async throws {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let activity = setup.decodedManifest()?.activity
    else { return }
    switch activity.kind.opponentSource {
    case .none, .supportFile:
        return
    case .paired:
        // A tournament match lands through `recordTournamentMatch`; a
        // student's own practice submission opened no row.
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

    guard try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student,
        let hill = try await Hill.of(
            submissionID: submissionID, testSetupID: testSetupID, userID: userID, activity: activity, on: db)
    else { return }
    let current = try await hill.holder(on: db)
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
            // Two first crownings can land together: both read an empty hill
            // and both reach this insert. The unique index keeps one, and the
            // record must name the same student (#1752).
            guard try await hill.crownFirst(userID: userID, submissionID: submissionID, on: db) else { return }
        }
        // A class record has one holder, and an activity run per group has a
        // hill in every lab: no lab's champion holds it.
        if case .course = hill {
            try await awardChampionRecords(setup: setup, userID: userID, submissionID: submissionID, on: db)
        }
    } else if let current, current.userID != userID {
        current.defences += 1
        try await current.update(on: db)
    }
}

/// Inserts the first champion row of a setup's course-wide hill
/// (`Hill.crownFirst`).
func crownFirstChampion(
    testSetupID: String, userID: UUID, submissionID: String, on db: any Database
) async throws -> Bool {
    try await Hill.course(testSetupID: testSetupID).crownFirst(userID: userID, submissionID: submissionID, on: db)
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
    outcomes: [TestOutcome], matches: [MatchReport]?, on db: any Database
) async throws {
    let open = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$completedAt == nil)
        .all()
    guard !open.isEmpty else { return }  // a replayed report

    var reportByIdentity: [String: MatchReport] = [:]
    for report in matches ?? [] { reportByIdentity[report.opponentIdentity] = report }
    let single = matchOutcome(from: outcomes)
    // A report with no per-match rows completes one row, and only the bot or
    // empty one: a claim can open a row per classmate, and completing every
    // one from a single outcome would record a result against students the
    // job never played (#1749). Any other unreported row stays open.
    let completesFromCollection = matches == nil && open.count == 1 && open[0].opponentSubmissionID == nil
    for row in open {
        if let report = reportByIdentity[row.opponentIdentity] {
            row.score = report.score
            row.metric = report.metric
            row.won = report.won
        } else if completesFromCollection {
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

    guard let setupID = setup.id, let activity = setup.decodedManifest()?.activity,
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }
    // A union kind materialises nothing: both halves of its reading — whose
    // code the class defeated, and whose code held up — are queries over the
    // rows just completed (`unionTally`). A standings row would answer only
    // the tester's half and would be read as the whole record.
    guard activity.kind.aggregation != .union else { return }
    // A lab group's standings row carries the group of the session the
    // submission was made in. With no session open the result grades and
    // the student's standing stays as it was (docs/lab-groups.md, slice 3c).
    let groupID: UUID?
    if activity.isPerGroup {
        guard
            let session = try await ActivitySessionStore.sessionAtSubmission(
                testSetupID: setupID, userID: userID, submissionID: submissionID, on: db)
        else {
            // A retest of the standing's own submission voided the rows it
            // counted (`voidCompletedMatrixRows`), so it counts nothing now.
            try await APIActivityStanding.query(on: db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$userID == userID)
                .filter(\.$submissionID == submissionID)
                .delete()
            return
        }
        groupID = session.groupID
    } else {
        groupID = nil
    }
    try await db.transaction { tx in
        try await lockStandings(of: setupID, on: tx)
        try await recomputeStanding(
            testSetupID: setupID, userID: userID, submissionID: submissionID, groupID: groupID, on: tx)
        // A class record has one holder, and a per-group round robin has a
        // leader in every lab: no lab's leader holds it.
        guard groupID == nil,
            let leader = try await rankedStandings(
                testSetupID: setupID, courseID: setup.courseID, groupID: nil, on: tx
            ).first
        else { return }
        try await awardTournamentWinnerRecords(
            setup: setup, userID: leader.standing.userID, submissionID: leader.standing.submissionID, on: tx)
    }
}

/// Serializes the standings write and the leader award for one assignment,
/// for the rest of the caller's transaction.
///
/// Two results landing together each wrote their own row, read the leader
/// without the other's row, and set the record, so the later write could
/// name a student the standings did not show first (#2192, the #1752
/// family). A no-op `UPDATE` of the setup row takes that row's lock on
/// Postgres and the write lock on SQLite. The second ingest waits for the
/// first to commit (or, on SQLite, is retried by the caller's
/// `withTransientDatabaseLockRetry`) and then reads both rows.
private func lockStandings(of setupID: String, on db: any Database) async throws {
    guard let sql = db as? (any SQLDatabase) else { return }
    try await sql.raw(
        "UPDATE \(unsafeRaw: APITestSetup.schema) SET id = id WHERE id = \(bind: setupID)"
    ).run()
}

/// Rewrites the student's standings row from `submissionID`'s completed
/// matches. A draw is a completed match the challenger did not win whose
/// score is exactly one half; a loss is any other non-win.
///
/// A match against nobody (`JobOpponent.noOpponentIdentity`: the first
/// submitter, with no classmate and no bundled bot) counts nothing. The row
/// exists so the job has a match, but it is not a result against anyone, and
/// counting it sat the first submitter last on a loss until a classmate
/// arrived (#1748). With nothing to count, the student has no standings row.
private func recomputeStanding(
    testSetupID: String, userID: UUID, submissionID: String, groupID: UUID?, on db: any Database
) async throws {
    let rows = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$completedAt != nil)
        .filter(\.$opponentIdentity != JobOpponent.noOpponentIdentity)
        .all()
    let wins = rows.count(where: { $0.won == true })
    let draws = rows.count(where: { $0.won != true && $0.score == 0.5 })
    let losses = rows.count - wins - draws
    let scoreSum = rows.compactMap(\.score).reduce(0, +)
    let existing = try await APIActivityStanding.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == userID)
        .first()
    if rows.isEmpty {
        try await existing?.delete(on: db)
    } else if let existing {
        existing.submissionID = submissionID
        existing.groupID = groupID
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
            updatedAt: Date(), groupID: groupID
        ).save(on: db)
    }
}

/// The standings, best first: average match score, then wins, then matches
/// played, then the earlier row. With `groupID`, one lab group's standings;
/// without, the whole class's rows only, so a lab's rows left from when the
/// activity ran per group never mix into the class standings.
func activityStandings(
    testSetupID: String, groupID: UUID? = nil, on db: any Database
) async throws
    -> [APIActivityStanding]
{
    try await APIActivityStanding.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$groupID == groupID)
        .all()
        .sorted { a, b in
            if a.averageScore != b.averageScore { return a.averageScore > b.averageScore }
            if a.wins != b.wins { return a.wins > b.wins }
            if a.played != b.played { return a.played > b.played }
            return (a.updatedAt ?? .distantPast) < (b.updatedAt ?? .distantPast)
        }
}

/// One standings row with the place the class sees.
struct RankedStanding: Sendable {
    let standing: APIActivityStanding
    /// 1 = first. Tied rows share the place of the first of them.
    let rank: Int
    let isTied: Bool
}

/// The standings as the class sees them: the rows of students still enrolled
/// in the course, best first (`activityStandings`), with one competition
/// rank per tie of average, wins and played.
///
/// The ONE ranking rule. The leaderboard page, the `standing` badge signal
/// and the standings-leader record all read it, so a tie or a student who
/// left the course cannot give the page one answer and the badge or the
/// record another (#2191).
func rankedStandings(
    testSetupID: String, courseID: UUID, groupID: UUID? = nil, on db: any Database
) async throws -> [RankedStanding] {
    let standings = try await activityStandings(testSetupID: testSetupID, groupID: groupID, on: db)
    let enrolled = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .filter(\.$userID ~~ standings.map(\.userID))
        .all()
    let roster = Set(enrolled.map(\.userID))
    let onRoster = standings.filter { roster.contains($0.userID) }

    var ranks: [Int] = []
    for (index, standing) in onRoster.enumerated() {
        let tiesPrevious = index > 0 && StandingKey(standing) == StandingKey(onRoster[index - 1])
        ranks.append(tiesPrevious ? ranks[index - 1] : index + 1)
    }
    let tieSizes = Dictionary(ranks.map { ($0, 1) }, uniquingKeysWith: +)
    return zip(onRoster, ranks).map { standing, rank in
        RankedStanding(standing: standing, rank: rank, isTied: (tieSizes[rank] ?? 1) > 1)
    }
}

/// The part of a standings row that decides its rank: two rows with equal
/// keys share a rank.
private struct StandingKey: Equatable {
    let averageScore: Double
    let wins: Int
    let played: Int

    init(_ standing: APIActivityStanding) {
        averageScore = standing.averageScore
        wins = standing.wins
        played = standing.played
    }
}

/// A student's place (1 = first, shared on a tie) and win count in the
/// standings, for the `standing` / `matchesWon` badge signals; nil when they
/// have no row, or have left the course. The place is the page's
/// (`rankedStandings`): in a per-group round robin, the place in the lab
/// group of the student's row; otherwise the place among the class rows,
/// so a lab row left from a per-group run has no place.
func standingSignals(
    testSetupID: String, userID: UUID, on db: any Database
) async throws -> (standing: Int, matchesWon: Int)? {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let own = try await APIActivityStanding.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$userID == userID)
            .first()
    else { return nil }
    // The board the page shows: the row's lab while the activity runs per
    // group, the whole class's rows otherwise (where a lab row is absent).
    let isPerGroup = setup.decodedManifest()?.activity?.isPerGroup == true
    let ranked = try await rankedStandings(
        testSetupID: testSetupID, courseID: setup.courseID, groupID: isPerGroup ? own.groupID : nil, on: db)
    guard let row = ranked.first(where: { $0.standing.userID == userID }) else { return nil }
    return (row.rank, row.standing.wins)
}

/// The course-wide hill's current holder; nil when the bot or nobody holds
/// it. A lab group's hill is read through `Hill.group`.
func currentChampion(testSetupID: String, on db: any Database) async throws -> APIActivityChampion? {
    try await Hill.course(testSetupID: testSetupID).holder(on: db) as? APIActivityChampion
}
