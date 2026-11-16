// APIServer/Routes/Web/WebRoutes+LiveBoard.swift
//
// The fast path of a live board's refresh (docs/live-board-cache.md), work
// items W2 and W3 of the live-lecture plan:
//
// 1. One aggregate query reads the board's fingerprint. With the shared
//    roster snapshot's digest, it gives the refresh's ETag before anything is
//    built, and a refresh that still holds that ETag is answered 304 at once.
//    While the board is quiet, that is almost every refresh.
// 2. A refresh that must build reads the students' handles and birds from
//    that snapshot, which every refresh at the same fingerprint shares, so a
//    change costs one roster load, not one per viewer. A snapshot is
//    captured again after `LiveBoardETag.bucketSeconds` at most.
//
// Only a metric board takes the fast path: the fingerprint covers its rows
// and nothing else. A board with a hill, or one per lab group, is built on
// every refresh, as before.

import Core
import Fluent
import Foundation
import Vapor

enum LiveBoardRefresh {
    /// The refresh already holds the current board.
    case notModified(Response)
    /// Build the board from `roster`, and answer with `etag`.
    case build(etag: String, roster: RosterSnapshot)
    /// Build the board the ordinary way, and answer with the hash of its HTML.
    case ordinary

    var etag: String? {
        if case .build(let etag, _) = self { return etag }
        return nil
    }

    var roster: RosterSnapshot? {
        if case .build(_, let roster) = self { return roster }
        return nil
    }
}

extension WebRoutes {
    /// True for an activity whose board the fingerprint fully describes.
    static func takesLiveBoardFastPath(_ activity: ClassActivity) -> Bool {
        activity.kind.aggregation == .leaderboard && activity.kind.opponentSource != .champion
            && !activity.isPerGroup
    }

    /// The fast path for one refresh, or `.ordinary` when the board must be
    /// built the ordinary way: a request that is not the `fragment` refresh,
    /// or a board the fingerprint does not describe.
    func liveBoardRefresh(
        req: Request, fragment: String, user: APIUser, setup: APITestSetup, activity: ClassActivity,
        readsAsStaff: Bool
    ) async throws -> LiveBoardRefresh {
        guard req.query[String.self, at: "fragment"] == fragment, Self.takesLiveBoardFastPath(activity) else {
            return .ordinary
        }
        let setupID = try setup.requireID()
        let courseID = setup.courseID
        guard
            let fingerprint = try await LiveBoardFingerprint.read(
                testSetupID: setupID, groupID: nil, staffCountsIn: readsAsStaff ? courseID : nil, on: req.db)
        else { return .ordinary }

        // The snapshot first: it is cached, and its digest is part of the tag.
        let now = Date()
        let db = req.db
        let roster = try await req.application.liveBoardSnapshots.snapshot(
            testSetupID: setupID, groupID: nil,
            fingerprint: "\(fingerprint.rowsToken)|\(LiveBoardETag.bucket(at: now))"
        ) {
            let entries = try await leaderboardEntries(testSetupID: setupID, on: db)
            return try await RosterSnapshot.capture(userIDs: entries.map(\.userID), courseID: courseID, on: db)
        }
        // The manifest too: an edit to the activity can change the board
        // (its kind, its window, its visibility) without changing a row.
        let etag = LiveBoardETag.tag(
            fingerprint: "\(fingerprint.token)|\(sha256HexDigest(Data(setup.manifest.utf8)))",
            rosterDigest: roster.digest,
            reader: LiveBoardETag.Reader(viewerID: user.id, isStaff: readsAsStaff, query: req.url.query ?? ""),
            windowState: activity.window.map { "\($0.state(at: now))" } ?? "none",
            now: now)
        if let notModified = Response.notModified(etag: etag, for: req) {
            return .notModified(notModified)
        }
        return .build(etag: etag, roster: roster)
    }
}
