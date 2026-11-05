// Sources/APIServer/BrightSpace/BrightSpacePagePresenter+LatestResultSync.swift
//
// Each student's latest grade-sync state on each assignment of a course, read
// for the LEARN tab summary (#2882).

import Fluent
import Foundation
import SQLKit

extension BrightSpacePagePresenter {

    /// Each student's latest result row per setup (highest `received_at`),
    /// reduced to its sync state.
    ///
    /// On SQL databases, `DISTINCT ON` picks that row in the database, so the
    /// query returns one narrow row per student, not every historical result
    /// with both models' columns. The earlier read decoded about 35 MB for a
    /// course of 65,536 submissions. Postgres executed it in 0.12 s and then
    /// waited 12 s on the client, which counts against `statement_timeout`
    /// (#2882). The scope is still the course's few setup IDs, never a list of
    /// submission IDs, which would pass the driver bind limit (#2764).
    static func latestResultSyncStates(
        setupIDs: [String], on db: any Database
    ) async throws -> [StudentKey: LatestSyncState] {
        guard !setupIDs.isEmpty else { return [:] }
        guard let sql = db as? (any SQLDatabase) else {
            return try await latestResultSyncStatesViaFluent(setupIDs: setupIDs, on: db)
        }
        struct LatestRow: Decodable {
            let testSetupID: String
            let userID: UUID
            let receivedAt: Date?
            let syncError: String?
            let syncedAt: Date?
            let syncPending: Bool?
            enum CodingKeys: String, CodingKey {
                case testSetupID = "test_setup_id"
                case userID = "user_id"
                case receivedAt = "received_at"
                case syncError = "brightspace_sync_error"
                case syncedAt = "brightspace_synced_at"
                case syncPending = "brightspace_sync_pending"
            }
        }
        // A NULL `received_at` sorts last, as `Date.distantPast` did in the
        // Swift fold; `r.id` breaks a tie so the pick is deterministic.
        let rows = try await sql.raw(
            """
            SELECT DISTINCT ON (s.test_setup_id, s.user_id)
                s.test_setup_id, s.user_id, r.received_at,
                r.brightspace_sync_error, r.brightspace_synced_at, r.brightspace_sync_pending
            FROM \(unsafeRaw: APIResult.schema) r
            INNER JOIN \(unsafeRaw: APISubmission.schema) s ON s.id = r.submission_id
            WHERE s.test_setup_id IN (\(binds: setupIDs))
              AND s.kind = \(bind: APISubmission.Kind.student)
              AND s.user_id IS NOT NULL
            ORDER BY s.test_setup_id, s.user_id, r.received_at DESC NULLS LAST, r.id
            """
        ).all(decoding: LatestRow.self)
        var latest: [StudentKey: LatestSyncState] = [:]
        for row in rows {
            latest[StudentKey(setupID: row.testSetupID, userID: row.userID)] = LatestSyncState(
                attemptedAt: row.receivedAt ?? Date.distantPast,
                error: row.syncError,
                syncedAt: row.syncedAt,
                pending: row.syncPending == true)
        }
        return latest
    }

    /// The same read through Fluent, for a database that is not SQL.
    private static func latestResultSyncStatesViaFluent(
        setupIDs: [String], on db: any Database
    ) async throws -> [StudentKey: LatestSyncState] {
        let results = try await APIResult.query(on: db)
            .join(APISubmission.self, on: \APIResult.$submissionID == \APISubmission.$id)
            .filter(APISubmission.self, \.$testSetupID ~~ setupIDs)
            .filter(APISubmission.self, \.$kind == APISubmission.Kind.student)
            .all()
        var latest: [StudentKey: LatestSyncState] = [:]
        for result in results {
            let submission = try result.joined(APISubmission.self)
            guard let userID = submission.userID else { continue }
            let key = StudentKey(setupID: submission.testSetupID, userID: userID)
            let received = result.receivedAt ?? Date.distantPast
            if let existing = latest[key], existing.attemptedAt >= received { continue }
            latest[key] = LatestSyncState(
                attemptedAt: received,
                error: result.brightspaceSyncError,
                syncedAt: result.brightspaceSyncedAt,
                pending: result.brightspaceSyncPending == true)
        }
        return latest
    }
}
