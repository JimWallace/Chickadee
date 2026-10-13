// APIServer/Routes/Web/WebRoutes+TournamentArena.swift
//
// The projector arena's three requests (docs/class-activities.md, "Projector
// arena"). The present page (`Public/tournament-arena.js`) plays a
// browser-graded tournament one match at a time:
//
//   GET  /testsetups/:id/arena/next                     — the next match, or 204
//   GET  /testsetups/:id/arena/submissions/:sid         — one entrant's upload
//   POST /testsetups/:id/arena/matches/:sid/result      — the match's result
//
// Course staff only, like Present mode. The arena runs in the presenter's
// browser, so a submission it downloads is one a staff member can already
// read; a student can reach none of these.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    /// The match the arena plays next, or 204 No Content when none waits.
    @Sendable
    func arenaNextMatch(req: Request) async throws -> Response {
        let setup = try await requireArenaSetup(req)
        guard let match = try await nextArenaMatch(testSetupID: setup.id ?? "", on: req.db) else {
            return Response(status: .noContent)
        }
        return try await ArenaMatchResponse(match).encodeResponse(for: req)
    }

    /// One side of a waiting arena match: the match's own upload (the home
    /// entrant's) or the away entrant's snapshotted submission. Any other
    /// submission is a 404, so the route reads no more than the bracket shows.
    @Sendable
    func arenaSubmissionDownload(req: Request) async throws -> Response {
        let setup = try await requireArenaSetup(req)
        guard let submissionID = req.parameters.get("submissionID"),
            try await isArenaEntrySubmission(submissionID, testSetupID: setup.id ?? "", on: req.db),
            let submission = try await APISubmission.find(submissionID, on: req.db)
        else { throw Abort(.notFound) }
        return try await req.fileio.asyncStreamFile(at: submission.zipPath)
    }

    /// Lands the result the arena played. 409 when the match was played
    /// already (a second presenter, or a replay), 404 when it is not a match
    /// that waits for the arena.
    @Sendable
    func arenaMatchResult(req: Request) async throws -> HTTPStatus {
        let setup = try await requireArenaSetup(req)
        guard let matchSubmissionID = req.parameters.get("submissionID") else { throw Abort(.notFound) }
        let body = try req.content.decode(ArenaResultBody.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection: TestOutcomeCollection
        do {
            // The same serialized-size budget as every other result (#1157).
            collection = try decoder.decode(TestOutcomeCollection.self, from: Data(body.collection.utf8))
                .truncatingOversizedOutput().0
        } catch let error as DecodingError {
            throw AppError.unprocessable(reason: "Invalid TestOutcomeCollection: \(error)")
        }
        // The browser built the collection before it knew the match's ID;
        // reconcile it as the browser result route does.
        guard let match = try await APISubmission.find(matchSubmissionID, on: req.db) else {
            throw Abort(.notFound)
        }
        let reconciled = BrowserResultRoutes.reconcileBrowserCollection(
            collection, submissionID: matchSubmissionID, attemptNumber: match.attemptNumber ?? 1)
        do {
            try await recordArenaMatch(
                matchSubmissionID: matchSubmissionID, testSetupID: setup.id ?? "", collection: reconciled,
                application: req.application, on: req.db)
        } catch ArenaResultError.notAnArenaMatch {
            throw Abort(.notFound)
        } catch ArenaResultError.alreadyPlayed {
            throw Abort(.conflict, reason: "This match has been played already.")
        }
        return .noContent
    }

    /// The setup of an arena request, for course staff, when its activity is
    /// a tournament kind. Anything else is a 404.
    private func requireArenaSetup(_ req: Request) async throws -> APITestSetup {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db),
            setup.decodedManifest()?.activity?.kind.aggregation == .bracket,
            try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        else { throw Abort(.notFound) }
        return setup
    }
}

/// The body of an arena result: the collection as the browser runner built
/// it, JSON-encoded, as the browser result route takes it.
struct ArenaResultBody: Content {
    var collection: String
}
