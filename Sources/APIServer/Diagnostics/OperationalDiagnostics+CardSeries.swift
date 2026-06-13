// Sources/APIServer/Diagnostics/OperationalDiagnostics+CardSeries.swift
//
// Builder for `GET /admin/metrics/cards`: headline + sparkline series for
// the five admin diagnostic cards, computed for every selectable window
// (24h / 7d / 30d).
//
// RunnerSnapshot is the one source whose volume is driven by a timer (a
// heartbeat every ~30s), so 30 days is tens of thousands of rows — far more
// than the submission-bound job-metric / queue-depth sources.  We therefore
// pre-aggregate it to per-5-minute summed load *in the database* on Postgres
// (production), collapsing that scan to a few hundred rows.  SQLite (dev /
// tests) keeps an equivalent Swift aggregation: the data is tiny there and it
// sidesteps SQLite's ambiguous Date storage in raw SQL.  Both paths produce
// the same `RunnerLoadPoint` list, so the card math downstream is identical.

import Fluent
import Foundation
import SQLKit
import Vapor

/// Summed runner load over one fixed time bucket: total busy slots and total
/// capacity across every runner that reported in the bucket.
struct RunnerLoadPoint: Sendable {
    let bucketStart: Date
    let totalActive: Int
    let totalMax: Int
}

/// Width of the load pre-aggregation bucket.  Five minutes is far finer than
/// the smallest *display* bucket (the 24h window's 1-hour bars), so per-bucket
/// peaks stay faithful, while capping a 30-day scan at ~8.6k summed rows.
private let loadBucketSeconds = 300

extension OperationalDiagnosticsService {

    /// Builds the per-card sparkline payload.  All three windows are derived
    /// from one trailing fetch of the longest (30-day) window per source, so
    /// the dashboard's poll costs a fixed handful of queries regardless of how
    /// many windows the cards can cycle through.
    func metricsCardSeries(on db: Database, now: Date = Date()) async throws -> MetricsCardSeriesResponse {
        let longestWindow = MetricsCardWindow.allCases.max { $0.totalSeconds < $1.totalSeconds } ?? .month
        let outerStart = now.addingTimeInterval(-longestWindow.totalSeconds)

        // Job metrics are submission-bound (one row per job) and P95 can't be
        // aggregated in portable SQL, so this stays a raw load — projected to
        // only the columns the accumulators read.
        let jobMetrics = try await JobExecutionMetric.query(on: db)
            .filter(\.$completedAt >= outerStart)
            .field(\.$completedAt)
            .field(\.$queueWaitMs)
            .field(\.$executionMs)
            .field(\.$finalStatus)
            .all()
        // RunnerSnapshot is pre-aggregated (see file header).
        let loadPoints = try await runnerLoadPoints(since: outerStart, on: db)
        let queueTimeline = try await queueDepthTimeline(windowStart: outerStart, now: now, on: db)

        let windows = MetricsCardWindow.allCases.map { window in
            cardWindowSeries(
                window: window,
                now: now,
                jobMetrics: jobMetrics,
                loadPoints: loadPoints,
                queueTimeline: queueTimeline
            )
        }
        return MetricsCardSeriesResponse(generatedAt: now, windows: windows)
    }

    private func cardWindowSeries(
        window: MetricsCardWindow,
        now: Date,
        jobMetrics: [JobExecutionMetric],
        loadPoints: [RunnerLoadPoint],
        queueTimeline: QueueDepthTimeline
    ) -> MetricsCardWindowSeries {
        let grid = window.bucketWindow(endingAt: now)
        let jobBuckets = MetricBucketAccumulators.accumulateJobMetrics(jobMetrics, window: grid)

        let queueSeries = MetricsCardAccumulators.perBucketMaxQueueDepth(
            timeline: queueTimeline, window: grid)
        let jobsSeries = jobBuckets.map(\.completedJobs)

        // Headline P95s are computed over the window's full value set, not
        // averaged bucket P95s, so the 24h numbers match `/admin/metrics`.
        let inWindowMetrics = jobMetrics.filter { ($0.completedAt ?? .distantPast) >= grid.windowStart }
        let waitHeadline = MetricBucketAccumulators.percentile95(inWindowMetrics.compactMap(\.queueWaitMs))
        let executionHeadline = MetricBucketAccumulators.percentile95(
            inWindowMetrics.compactMap(\.executionMs))

        let load = loadSeriesAndPeak(points: loadPoints, grid: grid)

        let bucketLabels = (0..<grid.bucketCount).map { index in
            window.label(forBucketStart: grid.bucketStart(forIndex: index))
        }

        return MetricsCardWindowSeries(
            window: window.rawValue,
            label: window.displayLabel,
            bucketLabels: bucketLabels,
            maxQueueDepth: MetricsCardSeries(
                headline: queueSeries.max(),
                series: queueSeries.map { Optional($0) }
            ),
            jobsProcessed: MetricsCardSeries(
                headline: jobsSeries.reduce(0, +),
                series: jobsSeries.map { Optional($0) }
            ),
            load: MetricsCardLoadSeries(
                activeJobs: load.peakActive,
                capacity: load.peakMax,
                series: load.series
            ),
            queueWaitP95Ms: MetricsCardSeries(
                headline: waitHeadline,
                series: jobBuckets.map { MetricBucketAccumulators.percentile95($0.queueWaitValues) }
            ),
            executionP95Ms: MetricsCardSeries(
                headline: executionHeadline,
                series: jobBuckets.map { MetricBucketAccumulators.percentile95($0.executionValues) }
            )
        )
    }

    /// Per-display-bucket peak utilization% and the window's peak load pair,
    /// derived from the pre-aggregated load points.  Only points with capacity
    /// contribute; a display bucket with no reporting runner stays `nil` (an
    /// empty slot, not 0%).
    private func loadSeriesAndPeak(
        points: [RunnerLoadPoint],
        grid: BucketWindow
    ) -> (series: [Int?], peakActive: Int?, peakMax: Int?) {
        var series = [Int?](repeating: nil, count: grid.bucketCount)
        var peak: (active: Int, max: Int)?

        for point in points {
            guard point.totalMax > 0, let index = grid.bucketIndex(for: point.bucketStart) else { continue }
            let utilization = Int((Double(point.totalActive) / Double(point.totalMax) * 100).rounded())
            series[index] = series[index].map { Swift.max($0, utilization) } ?? utilization

            if let current = peak {
                let currentRatio = Double(current.active) / Double(current.max)
                let pointRatio = Double(point.totalActive) / Double(point.totalMax)
                if pointRatio > currentRatio
                    || (pointRatio == currentRatio && point.totalActive > current.active)
                {
                    peak = (point.totalActive, point.totalMax)
                }
            } else {
                peak = (point.totalActive, point.totalMax)
            }
        }
        return (series, peak?.active, peak?.max)
    }

    /// Summed runner load per `loadBucketSeconds` bucket since `outerStart`.
    /// Postgres aggregates server-side; every other driver (SQLite in dev /
    /// tests) aggregates in Swift over the raw rows.
    func runnerLoadPoints(since outerStart: Date, on db: Database) async throws -> [RunnerLoadPoint] {
        if let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" {
            return try await runnerLoadPointsViaPostgres(sql, since: outerStart)
        }
        return try await runnerLoadPointsInSwift(since: outerStart, on: db)
    }

    /// One column per (bucket, runner) is reduced to its peak load, then summed
    /// across runners per bucket — entirely in the database.  Mirrors the
    /// Swift fallback's semantics.
    private func runnerLoadPointsViaPostgres(
        _ sql: SQLDatabase,
        since outerStart: Date
    ) async throws -> [RunnerLoadPoint] {
        struct LoadRow: Decodable {
            let bucketIndex: Int
            let totalActive: Int
            let totalMax: Int
            enum CodingKeys: String, CodingKey {
                case bucketIndex = "bucket_index"
                case totalActive = "total_active"
                case totalMax = "total_max"
            }
        }

        let rows = try await sql.raw(
            """
            -- active_jobs / max_jobs are bigint columns, so MAX(...) is bigint
            -- and SUM(bigint) widens to NUMERIC, which PostgresKit can't decode
            -- into Swift.Int.  Cast the sums back to BIGINT (the per-bucket
            -- totals are tiny) so they decode cleanly.
            SELECT
                bucket_index,
                CAST(SUM(a) AS BIGINT) AS total_active,
                CAST(SUM(m) AS BIGINT) AS total_max
            FROM (
                SELECT
                    CAST(FLOOR(EXTRACT(EPOCH FROM recorded_at) / \(unsafeRaw: String(loadBucketSeconds))) AS BIGINT)
                        AS bucket_index,
                    runner_id,
                    MAX(active_jobs) AS a,
                    MAX(max_jobs) AS m
                FROM \(unsafeRaw: RunnerSnapshot.schema)
                WHERE recorded_at >= \(bind: outerStart)
                GROUP BY bucket_index, runner_id
            ) per_runner
            GROUP BY bucket_index
            ORDER BY bucket_index
            """
        ).all(decoding: LoadRow.self)

        return rows.map { row in
            RunnerLoadPoint(
                bucketStart: Date(timeIntervalSince1970: Double(row.bucketIndex * loadBucketSeconds)),
                totalActive: row.totalActive,
                totalMax: row.totalMax
            )
        }
    }

    /// Swift-side equivalent of `runnerLoadPointsViaPostgres`, used on SQLite
    /// (dev / tests) where the data is small.  Per (bucket, runner) keep the
    /// peak active/capacity, then sum across runners per bucket.
    private func runnerLoadPointsInSwift(
        since outerStart: Date,
        on db: Database
    ) async throws -> [RunnerLoadPoint] {
        let snapshots = try await RunnerSnapshot.query(on: db)
            .filter(\.$recordedAt >= outerStart)
            .field(\.$recordedAt)
            .field(\.$runnerID)
            .field(\.$activeJobs)
            .field(\.$maxJobs)
            .all()

        // bucket index -> runner id -> (peak active, peak max) in that bucket.
        var perRunner: [Int: [String: (active: Int, max: Int)]] = [:]
        for snapshot in snapshots {
            let bucket = Int(snapshot.recordedAt.timeIntervalSince1970) / loadBucketSeconds
            var runners = perRunner[bucket] ?? [:]
            let existing = runners[snapshot.runnerID]
            runners[snapshot.runnerID] = (
                active: Swift.max(existing?.active ?? 0, snapshot.activeJobs),
                max: Swift.max(existing?.max ?? 0, snapshot.maxJobs)
            )
            perRunner[bucket] = runners
        }

        return perRunner.keys.sorted().map { bucket in
            let runners = perRunner[bucket] ?? [:]
            return RunnerLoadPoint(
                bucketStart: Date(timeIntervalSince1970: Double(bucket * loadBucketSeconds)),
                totalActive: runners.values.reduce(0) { $0 + $1.active },
                totalMax: runners.values.reduce(0) { $0 + $1.max }
            )
        }
    }
}
