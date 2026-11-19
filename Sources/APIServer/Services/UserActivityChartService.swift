// APIServer/Services/UserActivityChartService.swift
//
// Aggregates `user_activity_events` into the bar-chart series shown on the
// admin dashboard: "distinct active users per time bucket" over a trailing
// window (24 hours / 1 week / 1 month).
//
// Buckets are fixed-duration slots rolling back from `now` (not calendar
// aligned), which keeps the math DST-safe and the query a single trailing
// range scan.  Postgres counts the distinct users of each bucket, so the
// request reads one row per bucket, not one per event.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

/// The selectable chart windows.  Raw values are the query-string tokens.
enum ActivityWindow: String, CaseIterable, Sendable {
    case day = "24h"
    case week = "1w"
    case month = "1m"

    /// Number of buckets (bars) in this window.
    var bucketCount: Int {
        switch self {
        case .day: return 24  // one bar per hour
        case .week: return 7  // one bar per day
        case .month: return 30  // one bar per day
        }
    }

    /// Duration of one bucket, in seconds.
    var bucketSeconds: TimeInterval {
        switch self {
        case .day: return 3600
        case .week, .month: return 86_400
        }
    }

    /// Total span covered by the window.
    var totalSeconds: TimeInterval { Double(bucketCount) * bucketSeconds }

    /// Short label shown under each bar, e.g. "14:00" (day) or "Jun 2" (week/
    /// month).  Formatted in America/Toronto to match the rest of the UI.
    func label(forBucketStart start: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_CA")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        switch self {
        case .day:
            fmt.dateFormat = "HH:mm"
        case .week, .month:
            fmt.dateFormat = "MMM d"
        }
        return fmt.string(from: start)
    }
}

/// One bar in the activity chart.
struct ActivityBucket: Content {
    /// X-axis label (already localised to America/Toronto).
    let label: String
    /// ISO-8601 start of the bucket (for tooltips / debugging).
    let startISO: String
    /// Distinct active users observed in this bucket.
    let count: Int
}

/// The chart payload returned by the JSON endpoint and embedded in the
/// initial server-rendered page.
struct ActivityChartData: Content {
    let window: String
    let generatedAt: String
    let buckets: [ActivityBucket]
}

enum UserActivityChartService {
    /// Builds the activity series for `window`, ending at `now`.
    static func chartData(
        window: ActivityWindow,
        on db: any Database,
        now: Date = Date()
    ) async throws -> ActivityChartData {
        let windowStart = now.addingTimeInterval(-window.totalSeconds)

        let bucketCount = window.bucketCount
        let bucketSeconds = window.bucketSeconds
        let counts = try await distinctUsersPerBucket(
            from: windowStart, through: now, bucketSeconds: bucketSeconds, bucketCount: bucketCount, on: db)

        let buckets = (0..<bucketCount).map { index -> ActivityBucket in
            let start = windowStart.addingTimeInterval(Double(index) * bucketSeconds)
            return ActivityBucket(
                label: window.label(forBucketStart: start),
                startISO: iso8601String(start),
                count: counts[index] ?? 0
            )
        }

        return ActivityChartData(
            window: window.rawValue,
            generatedAt: iso8601String(now),
            buckets: buckets
        )
    }

    /// The number of distinct users with an event in each bucket of
    /// `[start, end]`, keyed by bucket index; an empty bucket is absent.
    /// Postgres groups the events, so a month window of hundreds of thousands
    /// of events comes back as at most `bucketCount` rows. The index is the
    /// whole buckets since `start`, clamped to `0..<bucketCount` so an event
    /// at exactly `end` lands in the last bucket rather than past it.
    private static func distinctUsersPerBucket(
        from start: Date, through end: Date, bucketSeconds: TimeInterval, bucketCount: Int, on db: any Database
    ) async throws -> [Int: Int] {
        guard let sql = db as? (any SQLDatabase) else {
            // Non-SQL fallback (not hit by the Postgres driver in use).
            var users: [Int: Set<UUID>] = [:]
            for event in try await APIUserActivityEvent.query(on: db)
                .filter(\.$createdAt >= start)
                .filter(\.$createdAt <= end)
                .field(\.$userID)
                .field(\.$createdAt)
                .all()
            {
                guard let createdAt = event.createdAt else { continue }
                let index = min(max(Int(createdAt.timeIntervalSince(start) / bucketSeconds), 0), bucketCount - 1)
                users[index, default: []].insert(event.userID)
            }
            return users.mapValues(\.count)
        }
        let rows = try await sql.raw(
            """
            SELECT LEAST(GREATEST(
                     floor(extract(epoch FROM (created_at - \(bind: start))) / \(bind: bucketSeconds)), 0),
                     \(bind: bucketCount - 1))::int AS bucket,
                   count(DISTINCT user_id)::int AS users
            FROM \(unsafeRaw: APIUserActivityEvent.schema)
            WHERE created_at >= \(bind: start) AND created_at <= \(bind: end)
            GROUP BY 1
            """
        ).all()
        var counts: [Int: Int] = [:]
        for row in rows {
            counts[try row.decode(column: "bucket", as: Int.self)] = try row.decode(column: "users", as: Int.self)
        }
        return counts
    }
}
