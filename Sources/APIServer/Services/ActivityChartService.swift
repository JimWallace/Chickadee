// APIServer/Services/ActivityChartService.swift
//
// Aggregates `user_activity_events` into the bar-chart series shown on the
// admin dashboard: "distinct active users per time bucket" over a trailing
// window (24 hours / 1 week / 1 month).
//
// Buckets are fixed-duration slots rolling back from `now` (not calendar
// aligned), which keeps the math DST-safe and the query a single trailing
// range scan.  Aggregation is done in Swift over the fetched rows rather than
// in SQL so it works identically on SQLite (dev/tests) and Postgres (prod)
// without dialect-specific date functions.

import Fluent
import Foundation
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

enum ActivityChartService {
    /// Builds the activity series for `window`, ending at `now`.
    static func chartData(
        window: ActivityWindow,
        on db: Database,
        now: Date = Date()
    ) async throws -> ActivityChartData {
        let windowStart = now.addingTimeInterval(-window.totalSeconds)

        // Single trailing range scan; only the small set of in-window rows is
        // fetched and bucketed in memory.
        let events = try await APIUserActivityEvent.query(on: db)
            .filter(\.$createdAt >= windowStart)
            .filter(\.$createdAt <= now)
            .all()

        let bucketCount = window.bucketCount
        let bucketSeconds = window.bucketSeconds
        var bucketUsers = [Set<UUID>](repeating: [], count: bucketCount)

        for event in events {
            guard let createdAt = event.createdAt else { continue }
            let offset = createdAt.timeIntervalSince(windowStart)
            var index = Int(offset / bucketSeconds)
            // Clamp defensively so the boundary at exactly `now` lands in the
            // last bucket rather than overflowing the array.
            if index < 0 { index = 0 }
            if index >= bucketCount { index = bucketCount - 1 }
            bucketUsers[index].insert(event.userID)
        }

        let iso = ISO8601DateFormatter()
        let buckets = (0..<bucketCount).map { index -> ActivityBucket in
            let start = windowStart.addingTimeInterval(Double(index) * bucketSeconds)
            return ActivityBucket(
                label: window.label(forBucketStart: start),
                startISO: iso.string(from: start),
                count: bucketUsers[index].count
            )
        }

        return ActivityChartData(
            window: window.rawValue,
            generatedAt: iso.string(from: now),
            buckets: buckets
        )
    }
}
