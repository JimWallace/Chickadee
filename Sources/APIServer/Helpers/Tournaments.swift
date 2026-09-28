// APIServer/Helpers/Tournaments.swift
//
// The server half of a tournament (docs/class-activities.md, "Tournaments"):
// starting one on a snapshot of the class, enqueueing a match job per slot,
// telling the claim path which opponent a match job stages, and advancing
// the round when its last match lands. The pairing rules themselves are
// `TournamentPairing` in Core; this file only stores what they produce.
//
// A match is a `tournamentMatch` SUBMISSION: a frozen copy of the home
// entrant's upload (same file, same filename), enqueued pending and claimed
// like any job, with the away entrant's snapshotted submission staged as
// the opponent on the hill's single-submission contract. It is never a
// grade of record — every listing and aggregate filters on `student` — and
// its result reaches only the bracket.

import Core
import Fluent
import Foundation
import Vapor

/// Why a tournament could not start; each is the web banner and the MCP
/// error's message.
enum TournamentStartError: Error {
    case notATournamentKind
    case tooFewEntrants(Int)

    var reason: String {
        switch self {
        case .notATournamentKind:
            return "This assignment's class activity is not a tournament kind, so there is no bracket to run."
        case .tooFewEntrants(let count):
            return "A tournament needs at least two students with a complete submission; there "
                + (count == 1 ? "is 1." : "are \(count).")
        }
    }
}

/// Starts a tournament on the class as it stands: every enrolled `.student`
/// with a complete submission enters with their LATEST one, seeded in the
/// order those submissions arrived (1 = first). A run already in progress is
/// marked superseded — its landed matches keep their rows, its outstanding
/// jobs still complete their rows but move nothing — so a stalled run can
/// never block the class. Refuses on a kind with no bracket and on fewer
/// than two entrants.
@discardableResult
func startTournament(
    setup: APITestSetup, schedule: TournamentSchedule, startedBy: UUID?, on db: Database
) async throws -> APITournamentRun {
    guard let setupID = setup.id, setup.decodedManifest()?.activity?.kind.aggregation == .bracket else {
        throw TournamentStartError.notATournamentKind
    }
    let entrants = try await snapshotEntrants(setup: setup, on: db)
    guard entrants.count >= 2 else { throw TournamentStartError.tooFewEntrants(entrants.count) }

    for running in try await APITournamentRun.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$status == APITournamentRun.Status.running)
        .all()
    {
        running.status = APITournamentRun.Status.superseded
        try await running.update(on: db)
    }

    let run = try APITournamentRun(
        testSetupID: setupID, schedule: schedule, startedBy: startedBy, startedAt: Date(), entrants: entrants)
    try await run.save(on: db)
    let slots = TournamentPairing.firstRound(schedule: schedule, entrantCount: entrants.count)
    try await enqueueRound(run: run, slots: slots, on: db)
    return run
}

/// The latest complete student submission per enrolled student, seeded by
/// arrival order of those submissions.
private func snapshotEntrants(setup: APITestSetup, on db: Database) async throws -> [TournamentEntrant] {
    guard let setupID = setup.id else { return [] }
    // NULL role is a pre-migration student (the `role` accessor's default).
    let students = Set(
        try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == setup.courseID)
            .group(.or) { or in
                or.filter(\.$roleRaw == CourseRole.student.rawValue)
                or.filter(\.$roleRaw == .null)
            }
            .all()
            .map(\.userID))
    guard !students.isEmpty else { return [] }
    let candidates = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$status == SubmissionStatus.complete.rawValue)
        .filter(\.$userID ~~ Array(students))
        .sort(\.$submittedAt, .descending)
        .all()
    var latestByUser: [UUID: APISubmission] = [:]
    for candidate in candidates {
        guard let userID = candidate.userID, latestByUser[userID] == nil else { continue }
        latestByUser[userID] = candidate
    }
    return latestByUser.values
        .sorted { a, b in
            let (ta, tb) = (a.submittedAt ?? .distantPast, b.submittedAt ?? .distantPast)
            if ta != tb { return ta < tb }
            return (a.id ?? "") < (b.id ?? "")
        }
        .enumerated()
        .compactMap { index, submission in
            guard let userID = submission.userID, let submissionID = submission.id else { return nil }
            return TournamentEntrant(seed: index + 1, userID: userID, submissionID: submissionID)
        }
}

/// Stores a round's slots and enqueues one match job per pairing. A bye is
/// stored already won, with no job.
private func enqueueRound(run: APITournamentRun, slots: [TournamentSlot], on db: Database) async throws {
    let runID = try run.requireID()
    let entrants = run.entrants
    for slot in slots {
        var matchSubmissionID: String?
        if !slot.isBye, let home = entrants.first(where: { $0.seed == slot.homeSeed }),
            let original = try await APISubmission.find(home.submissionID, on: db)
        {
            let match = APISubmission(
                id: "sub_\(UUID().uuidString.lowercased().prefix(8))",
                testSetupID: run.testSetupID,
                zipPath: original.zipPath,
                attemptNumber: original.attemptNumber ?? 1,
                filename: original.filename,
                userID: home.userID,
                kind: APISubmission.Kind.tournamentMatch)
            try await match.save(on: db)
            matchSubmissionID = match.id
        }
        try await APITournamentMatch(
            tournamentID: runID, slot: slot, matchSubmissionID: matchSubmissionID,
            completedAt: slot.winnerSeed == nil ? nil : Date()
        ).save(on: db)
    }
}

/// The opponent a match job stages: the away entrant's snapshotted
/// submission, with the slot it plays. Nil when the submission is not a
/// tournament match still waiting for its result.
func pairedOpponent(
    for submission: APISubmission, on db: Database
) async throws -> (slot: APITournamentMatch, run: APITournamentRun, away: APISubmission)? {
    guard submission.kind == APISubmission.Kind.tournamentMatch, let submissionID = submission.id,
        let slot = try await APITournamentMatch.query(on: db)
            .filter(\.$matchSubmissionID == submissionID)
            .first(),
        let run = try await APITournamentRun.find(slot.tournamentID, on: db),
        let awaySeed = slot.awaySeed,
        let away = run.entrants.first(where: { $0.seed == awaySeed }),
        let awaySubmission = try await APISubmission.find(away.submissionID, on: db)
    else { return nil }
    return (slot, run, awaySubmission)
}

/// Lands a match job's result: completes the row the claim opened, records
/// the slot's winner — the home entrant when the script passed, the away
/// entrant otherwise, so an error, a timeout or a build failure can never
/// stall a round — and advances the run when the round's last match lands.
/// A replayed report finds the slot already decided and does nothing; a
/// slot of a superseded run is decided but moves nothing.
func recordTournamentMatch(
    submission: APISubmission, collection: TestOutcomeCollection, on db: Database
) async throws {
    guard submission.kind == APISubmission.Kind.tournamentMatch, let submissionID = submission.id,
        let slot = try await APITournamentMatch.query(on: db)
            .filter(\.$matchSubmissionID == submissionID)
            .first(),
        slot.winnerSeed == nil,
        let run = try await APITournamentRun.find(slot.tournamentID, on: db),
        let awaySeed = slot.awaySeed
    else { return }

    let entry = collection.buildStatus == .passed ? matchOutcome(from: collection.outcomes) : nil
    let homeWon = entry?.status == .pass
    if let row = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$completedAt == nil)
        .first()
    {
        row.score = entry?.score
        row.metric = entry?.metric
        row.won = homeWon
        row.completedAt = Date()
        try await row.update(on: db)
    }
    slot.winnerSeed = homeWon ? slot.homeSeed : awaySeed
    slot.completedAt = Date()
    try await slot.update(on: db)

    guard run.status == APITournamentRun.Status.running else { return }
    try await advanceTournamentIfRoundComplete(run: run, on: db)
}

/// Enqueues the next round once every slot of the current one has a winner,
/// or completes the run and awards the winner's record.
private func advanceTournamentIfRoundComplete(run: APITournamentRun, on db: Database) async throws {
    guard let runID = run.id, let schedule = run.tournamentSchedule else { return }
    let slots = try await APITournamentMatch.query(on: db).filter(\.$tournamentID == runID).all()
    let current = slots.filter { $0.round == run.currentRound }
    guard !current.isEmpty, current.allSatisfy({ $0.winnerSeed != nil }) else { return }
    let completed = slots.map(\.slot)
    let entrantCount = run.entrants.count
    if let next = TournamentPairing.nextRound(schedule: schedule, entrantCount: entrantCount, completed: completed) {
        try await enqueueRound(run: run, slots: next, on: db)
        run.currentRound += 1
        try await run.update(on: db)
        return
    }
    run.status = APITournamentRun.Status.complete
    run.completedAt = Date()
    if let winnerSeed = TournamentPairing.winner(schedule: schedule, entrantCount: entrantCount, completed: completed),
        let winner = run.entrants.first(where: { $0.seed == winnerSeed })
    {
        run.winnerUserID = winner.userID
        try await run.update(on: db)
        if let setup = try await APITestSetup.find(run.testSetupID, on: db) {
            try await awardTournamentWinnerRecords(
                setup: setup, userID: winner.userID, submissionID: winner.submissionID, on: db)
        }
    } else {
        try await run.update(on: db)
    }
}

/// The most recent run for the setup, any status, with its slots in round
/// and position order — what the bracket page and the run control show.
func latestTournament(
    testSetupID: String, on db: Database
) async throws -> (run: APITournamentRun, slots: [APITournamentMatch])? {
    guard
        let run = try await APITournamentRun.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .sort(\.$startedAt, .descending)
            .first(),
        let runID = run.id
    else { return nil }
    let slots = try await APITournamentMatch.query(on: db)
        .filter(\.$tournamentID == runID)
        .sort(\.$round, .ascending)
        .sort(\.$position, .ascending)
        .all()
    return (run, slots)
}
