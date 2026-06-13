// Sources/APIServer/Diagnostics/MetricsCardSeries.swift
//
// Types + pure bucket math behind `GET /admin/metrics/cards` — the sparkline
// series shown on the admin dashboard's diagnostic cards.  One response
// carries every selectable window (24h / 7d / 30d) for every card so the
// client can cycle windows instantly without extra round-trips.
//
// Mirrors the design of ActivityChartService: fixed-duration buckets rolling
// back from `now`, aggregated in Swift so SQLite (dev) and Postgres (prod)
// behave identically, labels formatted in America/Toronto.

import Foundation
import Vapor

/// The selectable sparkline windows.  Raw values are the wire tokens
/// (matching the activity chart's `24h` / `1w` / `1m`).
enum MetricsCardWindow: String, CaseIterable, Sendable {
    case day = "24h"
    case week = "1w"
    case month = "1m"

    /// Short window chip shown on the card, e.g. "7d Max Queue".
    var displayLabel: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    /// Number of buckets (sparkline bars) in this window.
    var bucketCount: Int {
        switch self {
        case .day: return 24  // one bar per hour
        case .week: return 28  // one bar per 6 hours
        case .month: return 30  // one bar per day
        }
    }

    /// Duration of one bucket, in seconds.
    var bucketSeconds: Int {
        switch self {
        case .day: return 3600
        case .week: return 21_600
        case .month: return 86_400
        }
    }

    /// Total span covered by the window.
    var totalSeconds: TimeInterval { Double(bucketCount) * Double(bucketSeconds) }

    /// The bucket grid for this window ending at `now`.
    func bucketWindow(endingAt now: Date) -> BucketWindow {
        BucketWindow(
            windowStart: now.addingTimeInterval(-totalSeconds),
            bucketSeconds: bucketSeconds,
            bucketCount: bucketCount
        )
    }

    /// Tooltip label for a bucket start, localised to America/Toronto to
    /// match the rest of the UI.
    func label(forBucketStart start: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_CA")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        switch self {
        case .day:
            fmt.dateFormat = "HH:mm"
        case .week:
            fmt.dateFormat = "EEE HH:mm"
        case .month:
            fmt.dateFormat = "MMM d"
        }
        return fmt.string(from: start)
    }
}

/// One +1 (submitted) / −1 (assigned) step in the worker queue depth.
struct QueueDepthEvent: Sendable, Equatable {
    let date: Date
    let delta: Int
}

/// The queue depth expressed as a starting depth plus a sorted event stream,
/// so any sub-window's per-bucket maxima can be derived with one sweep.
struct QueueDepthTimeline: Sendable, Equatable {
    /// Depth at the timeline's start (jobs already pending when it opens).
    let initialDepth: Int
    /// Events at or after the timeline start, ascending; +1 deltas sort
    /// before −1 at equal timestamps (matching `maxQueueDepthSince`).
    let events: [QueueDepthEvent]
}

/// Headline value + per-bucket sparkline series for one card.  `nil` series
/// entries mean "no data in this bucket" (rendered as an empty slot, not 0).
struct MetricsCardSeries: Content, Sendable {
    let headline: Int?
    let series: [Int?]
}

/// The Max Load card: peak concurrent jobs / capacity over the window, with
/// a per-bucket peak-utilisation-percent sparkline.
struct MetricsCardLoadSeries: Content, Sendable {
    let activeJobs: Int?
    let capacity: Int?
    let series: [Int?]
}

/// All five card series for one window.
struct MetricsCardWindowSeries: Content, Sendable {
    let window: String
    let label: String
    let bucketLabels: [String]
    let maxQueueDepth: MetricsCardSeries
    let jobsProcessed: MetricsCardSeries
    let load: MetricsCardLoadSeries
    let queueWaitP95Ms: MetricsCardSeries
    let executionP95Ms: MetricsCardSeries
}

/// Payload of `GET /admin/metrics/cards`.
struct MetricsCardSeriesResponse: Content, Sendable {
    let generatedAt: Date
    let windows: [MetricsCardWindowSeries]
}

/// Pure sweep helpers for the card series.  No database access; exists so
/// the queue-depth bucket math is testable in isolation (same rationale as
/// MetricBucketAccumulators).
enum MetricsCardAccumulators {
    /// Peak queue depth over an entire timeline (the single-number form used
    /// by `/admin/metrics`' `maxQueueDepth`).
    static func maxQueueDepth(timeline: QueueDepthTimeline) -> Int {
        var depth = timeline.initialDepth
        var maxDepth = depth
        for event in timeline.events {
            depth = max(0, depth + event.delta)
            maxDepth = max(maxDepth, depth)
        }
        return maxDepth
    }

    /// Peak queue depth per bucket of `window`.  The timeline may start
    /// earlier than the window: events before `window.windowStart` fold into
    /// the depth carried into the first bucket.  Events past the last bucket
    /// boundary clamp into the final bucket so a step at exactly `now` still
    /// counts (parity with `maxQueueDepth(timeline:)`).
    static func perBucketMaxQueueDepth(
        timeline: QueueDepthTimeline,
        window: BucketWindow
    ) -> [Int] {
        var depth = timeline.initialDepth
        var eventIndex = 0
        let events = timeline.events

        // Fold pre-window events into the carried-in depth.
        while eventIndex < events.count, events[eventIndex].date < window.windowStart {
            depth = max(0, depth + events[eventIndex].delta)
            eventIndex += 1
        }

        var series: [Int] = []
        series.reserveCapacity(window.bucketCount)
        for bucketIndex in 0..<window.bucketCount {
            let isLastBucket = bucketIndex == window.bucketCount - 1
            let bucketEnd =
                isLastBucket
                ? Date.distantFuture
                : window.bucketStart(forIndex: bucketIndex + 1)
            var bucketMax = depth
            while eventIndex < events.count, events[eventIndex].date < bucketEnd {
                depth = max(0, depth + events[eventIndex].delta)
                bucketMax = max(bucketMax, depth)
                eventIndex += 1
            }
            series.append(bucketMax)
        }
        return series
    }
}
