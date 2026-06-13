// Sources/APIServer/Diagnostics/OperationalDiagnostics+CardSeries.swift
//
// Builder for `GET /admin/metrics/cards`: headline + sparkline series for
// the five admin diagnostic cards, computed for every selectable window
// (24h / 7d / 30d) from a single fetch of the longest window's rows.

import Fluent
import Foundation
import Vapor

extension OperationalDiagnosticsService {

    /// Builds the per-card sparkline payload.  All three windows are derived
    /// from one trailing fetch of the longest (30-day) window per source, so
    /// the dashboard's poll costs three queries regardless of how many
    /// windows the cards can cycle through.
    func metricsCardSeries(on db: Database, now: Date = Date()) async throws -> MetricsCardSeriesResponse {
        let longestWindow = MetricsCardWindow.allCases.max { $0.totalSeconds < $1.totalSeconds } ?? .month
        let outerStart = now.addingTimeInterval(-longestWindow.totalSeconds)

        // Project only the columns the accumulators read.  Both tables are
        // wide (JobExecutionMetric carries ~15 stage-timing columns;
        // RunnerSnapshot several) and this scan spans 30 days, so trimming the
        // selected columns materially cuts decode time and connection-hold.
        let jobMetrics = try await JobExecutionMetric.query(on: db)
            .filter(\.$completedAt >= outerStart)
            .field(\.$completedAt)
            .field(\.$queueWaitMs)
            .field(\.$executionMs)
            .field(\.$finalStatus)
            .all()
        let runnerSnapshots = try await RunnerSnapshot.query(on: db)
            .filter(\.$recordedAt >= outerStart)
            .field(\.$recordedAt)
            .field(\.$runnerID)
            .field(\.$activeJobs)
            .field(\.$maxJobs)
            .all()
        let queueTimeline = try await queueDepthTimeline(windowStart: outerStart, now: now, on: db)

        let windows = MetricsCardWindow.allCases.map { window in
            cardWindowSeries(
                window: window,
                now: now,
                jobMetrics: jobMetrics,
                runnerSnapshots: runnerSnapshots,
                queueTimeline: queueTimeline
            )
        }
        return MetricsCardSeriesResponse(generatedAt: now, windows: windows)
    }

    private func cardWindowSeries(
        window: MetricsCardWindow,
        now: Date,
        jobMetrics: [JobExecutionMetric],
        runnerSnapshots: [RunnerSnapshot],
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

        var snapshotsByBucket = [[RunnerSnapshot]](repeating: [], count: grid.bucketCount)
        for snapshot in runnerSnapshots {
            guard let index = grid.bucketIndex(for: snapshot.recordedAt) else { continue }
            snapshotsByBucket[index].append(snapshot)
        }
        let loadSeries = snapshotsByBucket.map { bucketSnapshots in
            bucketSnapshots.isEmpty ? nil : peakUtilizationPercent(from: bucketSnapshots)
        }
        let inWindowSnapshots = runnerSnapshots.filter { $0.recordedAt >= grid.windowStart }
        let peak = peakLoad(from: inWindowSnapshots)

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
                activeJobs: peak?.activeJobs,
                capacity: peak?.maxJobs,
                series: loadSeries
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
}
