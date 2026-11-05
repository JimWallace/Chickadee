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
    /// Postgres picks that row with `DISTINCT ON`, so the
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
            throw AppError.internalFailure(reason: "The LEARN sync summary needs a SQL database.")
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
}
