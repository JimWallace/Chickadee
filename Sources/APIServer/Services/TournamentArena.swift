// APIServer/Services/TournamentArena.swift
//
// The server half of the projector arena (docs/class-activities.md,
// "Projector arena"). A tournament on a browser-graded assignment puts no
// load on the runners: each match is stored with the `arena` status, and the
// present page plays the matches one at a time in the presenter's browser.
// This file chooses the next match to play and lands its result through the
// same `recordTournamentMatch` a runner's report uses, so a bracket advances
// the same way whoever plays it.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

/// One match that waits for the arena: who plays whom, and the seed the
/// runner would set for it.
struct ArenaMatch: Equatable {
    /// The `tournamentMatch` submission: the home entrant's frozen upload.
    let matchSubmissionID: String
    let homeFilename: String?
    /// The away entrant's snapshotted submission, staged as the opponent.
    let awaySubmissionID: String
    let awayFilename: String?
    let round: Int
    let position: Int
    let homeSeed: Int
    let awaySeed: Int
    /// `JobOpponent.matchSeed` over the same identity the worker uses for a
    /// paired match, so one match has one seed on either grader.
    let matchSeed: String
}

/// Why the arena refused a match result.
enum ArenaResultError: Error, Equatable {
    /// The submission is not a match of this setup that waits for the arena.
    case notAnArenaMatch
    /// The match was played already, by another presenter or a replay.
    case alreadyPlayed
}

/// The next match the arena plays for the setup: the lowest undecided slot
/// of the current round of the running tournament, or nil when none waits.
func nextArenaMatch(testSetupID: String, on db: any Database) async throws -> ArenaMatch? {
    guard let run = try await runningTournament(testSetupID: testSetupID, on: db), let runID = run.id else {
        return nil
    }
    let slots = try await APITournamentMatch.query(on: db)
        .filter(\.$tournamentID == runID)
        .filter(\.$round == run.currentRound)
        .filter(\.$winnerSeed == nil)
        .sort(\.$position, .ascending)
        .all()
    for slot in slots {
        guard let matchID = slot.matchSubmissionID,
            let match = try await APISubmission.find(matchID, on: db),
            match.statusValue == .arena,
            let paired = try await pairedOpponent(for: match, on: db),
            let awayID = paired.away.id,
            let awaySeed = slot.awaySeed
        else { continue }
        return ArenaMatch(
            matchSubmissionID: matchID, homeFilename: match.filename,
            awaySubmissionID: awayID, awayFilename: paired.away.filename,
            round: slot.round, position: slot.position, homeSeed: slot.homeSeed, awaySeed: awaySeed,
            matchSeed: JobOpponent.matchSeed(
                submissionID: matchID, opponentIdentity: JobOpponent.submissionIdentity(awayID)))
    }
    return nil
}

/// True when the submission is one side of an arena match of the setup's
/// running tournament: the match itself (the home entrant's upload) or the
/// away entrant's snapshotted submission. Only these may reach the
/// presenter's browser through the arena.
func isArenaEntrySubmission(_ submissionID: String, testSetupID: String, on db: any Database) async throws -> Bool {
    guard let run = try await runningTournament(testSetupID: testSetupID, on: db), let runID = run.id else {
        return false
    }
    let slots = try await APITournamentMatch.query(on: db)
        .filter(\.$tournamentID == runID)
        .filter(\.$round == run.currentRound)
        .all()
    for slot in slots where slot.matchSubmissionID != nil {
        if slot.matchSubmissionID == submissionID { return true }
        if let awaySeed = slot.awaySeed,
            run.entrants.first(where: { $0.seed == awaySeed })?.submissionID == submissionID
        {
            return true
        }
    }
    return false
}

/// Lands a result the arena played, in one transaction. It first claims the
/// match with one conditional update (`claimArenaMatch`), so of two
/// presenters who post one match at once, exactly one lands it, on SQLite and
/// Postgres alike. It then opens and completes the match row a runner's claim
/// would have opened, stores the result, and decides the slot and advances
/// the bracket through `recordTournamentMatch` (Fluent runs that call's own
/// transaction inline). A failure anywhere rolls the claim back, so the match
/// waits for the arena again and the presenter can replay it.
///
/// `collection` is already reconciled to the match (the route does it, as
/// the browser result route does): its submission ID must be the match's.
func recordArenaMatch(
    matchSubmissionID: String, testSetupID: String, collection: TestOutcomeCollection, application: Application,
    on db: any Database
) async throws {
    guard collection.submissionID == matchSubmissionID, collection.testSetupID == testSetupID else {
        throw ArenaResultError.notAnArenaMatch
    }
    try await db.transaction { tx in
        guard try await claimArenaMatch(matchSubmissionID, testSetupID: testSetupID, on: tx) else {
            let existing = try await APISubmission.find(matchSubmissionID, on: tx)
            let played =
                existing?.kind == APISubmission.Kind.tournamentMatch && existing?.testSetupID == testSetupID
                && existing?.statusValue == .complete
            throw played ? ArenaResultError.alreadyPlayed : .notAnArenaMatch
        }
        guard let match = try await APISubmission.find(matchSubmissionID, on: tx),
            let paired = try await pairedOpponent(for: match, on: tx), let awayID = paired.away.id
        else { throw ArenaResultError.notAnArenaMatch }
        let identity = JobOpponent.submissionIdentity(awayID)
        try await openMatch(
            testSetupID: testSetupID, submissionID: matchSubmissionID,
            opponent: ChosenOpponent(champion: paired.away, identity: identity),
            seed: JobOpponent.matchSeed(submissionID: matchSubmissionID, opponentIdentity: identity),
            round: paired.slot.round, on: tx)
        let prepared = try await ResultIngestEffects.prepareResult(
            collection, source: "arena", testSetupID: testSetupID, application: application, on: tx)
        try await prepared.row.saveWithCollection(json: prepared.json, on: tx)
        try await recordTournamentMatch(submission: match, collection: collection, on: tx)
    }
}

/// Moves one arena match of the setup to `complete` in one
/// `UPDATE … WHERE status = 'arena' … RETURNING` statement, which is atomic
/// on SQLite and Postgres (the `claimTournamentStep` pattern). True when this
/// caller's update landed; false when the match is not waiting for the arena,
/// or another presenter claimed it first.
private func claimArenaMatch(_ submissionID: String, testSetupID: String, on db: any Database) async throws -> Bool {
    guard let sql = db as? (any SQLDatabase) else { return false }
    let rows = try await sql.raw(
        """
        UPDATE \(unsafeRaw: APISubmission.schema) SET status = \(bind: SubmissionStatus.complete.rawValue) \
        WHERE id = \(bind: submissionID) AND test_setup_id = \(bind: testSetupID) \
        AND kind = \(bind: APISubmission.Kind.tournamentMatch) AND status = \(bind: SubmissionStatus.arena.rawValue) \
        RETURNING id
        """
    ).all()
    return !rows.isEmpty
}

/// The setup's running tournament, newest first; nil when none runs.
private func runningTournament(testSetupID: String, on db: any Database) async throws -> APITournamentRun? {
    try await APITournamentRun.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$status == APITournamentRun.Status.running)
        .sort(\.$startedAt, .descending)
        .first()
}
