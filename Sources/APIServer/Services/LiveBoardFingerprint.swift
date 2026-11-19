// APIServer/Services/LiveBoardFingerprint.swift
//
// What a metric board's rows depend on, read in one aggregate query that
// decodes no model: the count of ranked entries, the sum of their metrics,
// and the latest instant any of them was reached. A result that changes a
// student's best changes the sum or the instant, so a board refresh can
// compare this value with the one its last answer was built from and answer
// 304 without loading the roster (docs/live-board-cache.md).
//
// The roster itself (handles, birds, who has dropped) is not in it: the ETag
// that carries the fingerprint also carries a time bucket
// (`LiveBoardETag.bucketSeconds`), which bounds how long a roster change can
// go unseen.

import Fluent
import Foundation
import SQLKit

struct LiveBoardFingerprint: Sendable, Equatable, Hashable {
    let entryCount: Int
    let metricSum: Double
    /// Seconds since 1970 of the newest `reached_at`; 0 for an empty board.
    let latestReachedAt: Double
    /// The setup's submissions and the course's enrollments, counted only
    /// for a staff reader: the staff rows show a submission count that a
    /// result changes without changing a best, and the summary counts the
    /// students who have not ranked yet.
    let staffCounts: String?

    /// The rows alone, as stable text: the key of the shared roster
    /// snapshot, which a submission count does not change.
    var rowsToken: String {
        // Rounded: Postgres may add the rows in a different order from one
        // plan to the next, which can change the last bits of the sum.
        let sum = (metricSum * 1_000_000).rounded()
        return "\(entryCount):\(sum):\(latestReachedAt.bitPattern)"
    }

    /// Everything, as stable text, for the ETag.
    var token: String {
        staffCounts.map { "\(rowsToken):\($0)" } ?? rowsToken
    }

    /// Reads the fingerprint of `testSetupID`'s board, or of one lab group's
    /// board with `groupID`. With `staffCountsIn`, a course ID, the staff
    /// counts too.
    /// Nil on a database that is not SQL: the board is then built on every
    /// refresh, as it was before the fingerprint.
    static func read(
        testSetupID: String, groupID: UUID?, staffCountsIn courseID: UUID?, on db: any Database
    ) async throws -> LiveBoardFingerprint? {
        guard let sql = db as? (any SQLDatabase) else { return nil }
        let table = groupID == nil ? "leaderboard_entries" : "group_leaderboard_entries"
        var query = sql.select()
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "entry_count")
            .column(SQLFunction("SUM", args: SQLColumn("metric")), as: "metric_sum")
            .column(SQLFunction("MAX", args: SQLColumn("reached_at")), as: "latest")
            .from(table)
            .where("test_setup_id", .equal, SQLBind(testSetupID))
        if let groupID {
            query = query.where("group_id", .equal, SQLBind(groupID))
        }
        var count = 0
        var sum = 0.0
        var latest: Date?
        if let row = try await query.first() {
            count = try row.decode(column: "entry_count", as: Int?.self) ?? 0
            sum = try row.decode(column: "metric_sum", as: Double?.self) ?? 0
            latest = try row.decode(column: "latest", as: Date?.self)
        }
        var staffCounts: String?
        if let courseID {
            let submissions = try await sql.select()
                .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "n")
                .from("submissions")
                .where("test_setup_id", .equal, SQLBind(testSetupID))
                .first()
            let enrollments = try await sql.select()
                .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "n")
                .from("course_enrollments")
                .where("course_id", .equal, SQLBind(courseID))
                .first()
            let submissionCount = try submissions?.decode(column: "n", as: Int.self) ?? 0
            let enrollmentCount = try enrollments?.decode(column: "n", as: Int.self) ?? 0
            staffCounts = "\(submissionCount):\(enrollmentCount)"
        }
        return LiveBoardFingerprint(
            entryCount: count, metricSum: sum,
            latestReachedAt: latest?.timeIntervalSince1970 ?? 0, staffCounts: staffCounts)
    }
}
