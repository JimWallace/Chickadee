// APIServer/Services/Tournaments.swift
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
import SQLKit
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

    // One transaction, so a failure part-way leaves no run without its first
    // round, and the superseded runs stay running (#2184).
    return try await db.transaction { tx in
        for running in try await APITournamentRun.query(on: tx)
            .filter(\.$testSetupID == setupID)
            .filter(\.$status == APITournamentRun.Status.running)
            .all()
        {
            running.status = APITournamentRun.Status.superseded
            try await running.update(on: tx)
        }

        let run = try APITournamentRun(
            testSetupID: setupID, schedule: schedule, startedBy: startedBy, startedAt: Date(), entrants: entrants)
        try await run.save(on: tx)
        let slots = TournamentPairing.firstRound(schedule: schedule, entrantCount: entrants.count)
        try await enqueueRound(run: run, slots: slots, on: tx)
        return run
    }
}

/// The latest complete student submission per enrolled student, seeded by
/// arrival order of those submissions. The "latest per student" rule is the
/// one `latestStudentSubmissionsByUser` states for the classmate chooser and
/// the union read model; only the seeding order is the tournament's own
/// (#1751).
private func snapshotEntrants(setup: APITestSetup, on db: Database) async throws -> [TournamentEntrant] {
    let latestByUser = try await latestStudentSubmissionsByUser(setup: setup, on: db)
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
                id: freshShortID(prefix: "sub"),
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
/// A replayed report finds the slot already decided and does not decide it
/// again, but it still tries the advance, so a report whose advance failed
/// can finish it (#2184). A slot of a superseded run is decided but moves
/// nothing.
func recordTournamentMatch(
    submission: APISubmission, collection: TestOutcomeCollection, on db: Database
) async throws {
    guard submission.kind == APISubmission.Kind.tournamentMatch, let submissionID = submission.id,
        let slot = try await APITournamentMatch.query(on: db)
            .filter(\.$matchSubmissionID == submissionID)
            .first(),
        let awaySeed = slot.awaySeed
    else { return }
    if slot.winnerSeed == nil {
        try await decideSlot(slot, awaySeed: awaySeed, submissionID: submissionID, collection: collection, on: db)
    }
    try await advanceTournamentIfRoundComplete(runID: slot.tournamentID, on: db)
}

/// Completes the match row the claim opened and records the slot's winner.
private func decideSlot(
    _ slot: APITournamentMatch, awaySeed: Int, submissionID: String, collection: TestOutcomeCollection,
    on db: Database
) async throws {
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
}

/// Enqueues the next round once every slot of the current one has a winner,
/// or completes the run and awards the winner's record.
///
/// Safe to call from two ingests at once, and safe to call again (#2184).
/// It reads the run fresh, inside one transaction, and CLAIMS the step with
/// one conditional update that names the round it read
/// (`claimTournamentStep`). Only the ingest whose claim lands enqueues the
/// round or completes the run. Any other ingest, and a call for a round
/// that already advanced, does nothing. Before, each ingest advanced from
/// the run it had loaded before it decided its slot, so the last two matches
/// of a round could see the next round's undecided slots and complete the
/// run with no winner.
func advanceTournamentIfRoundComplete(runID: UUID, on db: Database) async throws {
    try await db.transaction { tx in
        guard let run = try await APITournamentRun.find(runID, on: tx),
            run.status == APITournamentRun.Status.running,
            let schedule = run.tournamentSchedule
        else { return }
        let round = run.currentRound
        let slots = try await APITournamentMatch.query(on: tx).filter(\.$tournamentID == runID).all()
        let current = slots.filter { $0.round == round }
        guard !current.isEmpty, current.allSatisfy({ $0.winnerSeed != nil }),
            !slots.contains(where: { $0.round > round })
        else { return }
        let completed = slots.map(\.slot)
        let entrantCount = run.entrants.count
        if let next = TournamentPairing.nextRound(schedule: schedule, entrantCount: entrantCount, completed: completed)
        {
            guard try await claimTournamentStep(runID: runID, round: round, to: .nextRound, on: tx) else { return }
            try await enqueueRound(run: run, slots: next, on: tx)
            return
        }
        guard try await claimTournamentStep(runID: runID, round: round, to: .complete, on: tx) else { return }
        run.completedAt = Date()
        guard
            let winnerSeed = TournamentPairing.winner(
                schedule: schedule, entrantCount: entrantCount, completed: completed),
            let winner = run.entrants.first(where: { $0.seed == winnerSeed })
        else {
            try await run.update(on: tx)
            return
        }
        run.winnerUserID = winner.userID
        try await run.update(on: tx)
        if let setup = try await APITestSetup.find(run.testSetupID, on: tx) {
            try await awardTournamentWinnerRecords(
                setup: setup, userID: winner.userID, submissionID: winner.submissionID, on: tx)
        }
    }
}

/// The step one ingest claims for a running tournament.
private enum TournamentStep {
    /// Moves `current_round` on by one.
    case nextRound
    /// Marks the run complete.
    case complete
}

/// Claims `step` for the run while it is still running at `round`, in one
/// `UPDATE … WHERE … RETURNING` statement, which is atomic on SQLite and
/// Postgres (the `SingleUseRecord` pattern). True when this caller's update
/// landed. False when another ingest claimed the step first.
private func claimTournamentStep(
    runID: UUID, round: Int, to step: TournamentStep, on db: Database
) async throws -> Bool {
    guard let sql = db as? SQLDatabase else { return true }
    let assignment: SQLQueryString
    switch step {
    case .nextRound: assignment = "current_round = \(bind: round + 1)"
    case .complete: assignment = "status = \(bind: APITournamentRun.Status.complete)"
    }
    let rows = try await sql.raw(
        """
        UPDATE \(unsafeRaw: APITournamentRun.schema) SET \(assignment) \
        WHERE id = \(bind: runID) AND status = \(bind: APITournamentRun.Status.running) \
        AND current_round = \(bind: round) RETURNING id
        """
    ).all()
    return !rows.isEmpty
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
