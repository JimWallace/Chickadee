// Sources/APIServer/Diagnostics/OperationalDiagnostics+Metrics.swift
//
// Snapshot / time-series / prune / request-timing extensions on
// OperationalDiagnosticsService.  Split from OperationalDiagnostics.swift
// for navigability.

import Core
import Fluent
import Foundation
import Vapor

extension OperationalDiagnosticsService {

    func rollingAverages(
        for runnerIDs: [String],
        sampleSize: Int = 50,
        on db: Database
    ) async throws -> [String: RunnerAverages] {
        guard !runnerIDs.isEmpty else { return [:] }
        let metrics = try await JobExecutionMetric.query(on: db)
            .filter(\.$runnerID ~~ runnerIDs)
            .sort(\.$completedAt, .descending)
            .limit(runnerIDs.count * sampleSize)
            .all()

        var execByRunner: [String: [Int]] = [:]
        var waitByRunner: [String: [Int]] = [:]
        for metric in metrics {
            guard let runnerID = metric.runnerID else { continue }
            if let executionMs = metric.executionMs, execByRunner[runnerID, default: []].count < sampleSize {
                execByRunner[runnerID, default: []].append(executionMs)
            }
            if let queueWaitMs = metric.queueWaitMs, waitByRunner[runnerID, default: []].count < sampleSize {
                waitByRunner[runnerID, default: []].append(queueWaitMs)
            }
        }

        var result: [String: RunnerAverages] = [:]
        for runnerID in runnerIDs {
            let exec = execByRunner[runnerID] ?? []
            let wait = waitByRunner[runnerID] ?? []
            result[runnerID] = RunnerAverages(
                avgExecutionMs: exec.isEmpty ? nil : exec.reduce(0, +) / exec.count,
                avgQueueWaitMs: wait.isEmpty ? nil : wait.reduce(0, +) / wait.count
            )
        }
        return result
    }

    func metricsSnapshot(req: Request) async throws -> InternalMetricsResponse {
        try await req.application.runnerProfiles.refreshActiveFlags(
            activeWindowSeconds: configuration.activeRunnerWindowSeconds,
            on: req.db
        )
        let now = Date()
        let windowHours = max(1, configuration.recentMetricsWindowHours)
        let windowStart = now.addingTimeInterval(Double(-windowHours) * 3600)

        // Pre-aggregated in the DB (see runnerLoadPoints) so the snapshot
        // endpoint never streams the full RunnerSnapshot scan.
        let loadPoints = try await runnerLoadPoints(since: windowStart, on: req.db)
        let activeSnapshots = await req.application.workerActivityStore.snapshotsSortedByRecent()
            .filter { now.timeIntervalSince($0.lastActive) <= configuration.activeRunnerWindowSeconds }
        // Only the columns the summary fold below reads — hydrating full
        // rows here was the same shape the timeseries endpoint had (#1382
        // item 7); see metricsTimeSeriesSnapshot for why the fold itself
        // stays in Swift.
        let recentMetrics = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$completedAt >= windowStart)
            .field(\.$finalStatus)
            .field(\.$queueWaitMs)
            .field(\.$executionMs)
            .all()
        let maxQueueDepth = try await maxQueueDepthSince(windowStart: windowStart, now: now, on: req.db)
        let peakLoadSnapshot = peakLoadPoint(from: loadPoints)

        var statusCounts: [String: Int] = [:]
        var queueWaitValues: [Int] = []
        var executionValues: [Int] = []
        for metric in recentMetrics {
            if let finalStatus = metric.finalStatus {
                statusCounts[finalStatus, default: 0] += 1
            }
            if let queueWaitMs = metric.queueWaitMs {
                queueWaitValues.append(queueWaitMs)
            }
            if let executionMs = metric.executionMs {
                executionValues.append(executionMs)
            }
        }

        let runnerLoads = activeSnapshots.map {
            RunnerLoadResponse(
                runnerID: $0.workerID,
                hostname: $0.hostname,
                activeJobs: $0.activeJobs,
                maxJobs: $0.maxConcurrentJobs,
                availableCapacity: max(0, $0.maxConcurrentJobs - $0.activeJobs),
                lastSeenAt: $0.lastActive,
                lastPollAt: $0.lastPollAt,
                lastHeartbeatAt: $0.lastHeartbeatAt,
                assignedJobsSinceStart: $0.serverAssignedJobCountSinceStart
            )
        }

        let compatibilitySnapshot = await compatibilityCounters.snapshot()

        return InternalMetricsResponse(
            generatedAt: now,
            maxQueueDepth: maxQueueDepth,
            jobsProcessed24h: recentMetrics.count,
            peakUtilizationPercent: peakLoadSnapshot.flatMap { peak in
                peak.max > 0 ? Int((Double(peak.active) / Double(peak.max) * 100).rounded()) : nil
            },
            maxLoadActiveJobs: peakLoadSnapshot?.active,
            maxLoadCapacity: peakLoadSnapshot?.max,
            activeRunners: activeSnapshots.count,
            runnerLoads: runnerLoads,
            recentWindowHours: windowHours,
            jobStatusCounts: JobFinalStatus.allCases.map {
                StatusCountResponse(status: $0.rawValue, count: statusCounts[$0.rawValue, default: 0])
            },
            queueWait: durationSummary(for: queueWaitValues),
            execution: durationSummary(for: executionValues),
            compatibility: compatibilitySnapshot
        )
    }

    func metricsTimeSeriesSnapshot(
        req: Request,
        hours requestedHours: Int?,
        bucketMinutes requestedBucketMinutes: Int?
    ) async throws -> InternalMetricsTimeSeriesResponse {
        let now = Date()
        let resolved = BucketWindow.resolve(
            hours: requestedHours,
            bucketMinutes: requestedBucketMinutes,
            defaultHours: configuration.recentMetricsWindowHours,
            now: now
        )
        let window = resolved.window

        // Runner snapshots are pre-aggregated per bucket (in SQL on Postgres).
        let runners = try await runnerTimeseriesSummaries(window: window, on: req.db)

        // Request / job metrics stay a Swift fold over raw rows, but only the
        // columns the accumulators read are hydrated (the window is clamped
        // to 72h, so the row count is bounded).  The per-bucket p95 is why
        // the fold cannot move into SQL: SQLite has no percentile aggregate,
        // and Postgres `percentile_disc` picks rank ceil(n·p) (1-based) where
        // `MetricBucketAccumulators.percentile` picks floor((n−1)·p)
        // (0-based) — they disagree at e.g. n = 10, so a SQL path would
        // silently change reported percentiles per backend.  Unordered on
        // purpose: the accumulators bucket by index and sort within
        // `percentile95`, so a DB sort here is wasted work.
        let requestMetrics = try await APIRequestMetric.query(on: req.db)
            .filter(\.$finishedAt >= window.windowStart)
            .field(\.$finishedAt)
            .field(\.$durationMs)
            .all()

        let jobMetrics = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$completedAt >= window.windowStart)
            .field(\.$completedAt)
            .field(\.$finalStatus)
            .field(\.$queueWaitMs)
            .field(\.$executionMs)
            .all()

        let requests = MetricBucketAccumulators.accumulateRequestMetrics(requestMetrics, window: window)
        let jobs = MetricBucketAccumulators.accumulateJobMetrics(jobMetrics, window: window)

        return InternalMetricsTimeSeriesResponse(
            generatedAt: now,
            windowHours: resolved.hours,
            bucketMinutes: resolved.bucketMinutes,
            buckets: MetricBucketAccumulators.buildBucketResponses(
                window: window,
                runners: runners,
                requests: requests,
                jobs: jobs
            )
        )
    }

    func pruneNow(on db: Database, logger: Logger) async {
        guard configuration.enabled else { return }
        await performPrune(on: db, logger: logger, now: Date())
    }

    func recordRequestMetric(
        _ metric: APIRequestMetric,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled else { return }
        guard
            shouldCaptureRequest(
                method: metric.method,
                path: metric.path,
                statusCode: metric.statusCode
            )
        else { return }

        do {
            try await metric.save(on: db)
        } catch {
            logger.warning(
                "diagnostics_request_metric_failed",
                metadata: [
                    "path": .string(metric.path),
                    "error": .string(String(describing: error)),
                ])
        }

        guard configuration.verboseRequestTiming || shouldAlwaysLogRequest(path: metric.path) else { return }
        logger.info(
            "request_completed",
            metadata: [
                "method": .string(metric.method),
                "path": .string(metric.path),
                "request_kind": .string(metric.requestKind ?? ""),
                "status_code": .stringConvertible(metric.statusCode),
                "duration_ms": .stringConvertible(metric.durationMs),
                "submission_id": .string(metric.submissionID ?? ""),
                "worker_id": .string(metric.workerID ?? ""),
            ])
    }

    private func shouldCaptureRequest(method: String, path: String, statusCode: Int) -> Bool {
        if configuration.verboseRequestTiming { return true }
        // Runner check-in noise: an idle poll (204, no job) and a healthy
        // heartbeat arrive at up-to-1/s per runner. Persisting a metric row
        // for each would be a DB INSERT per poll — the write amplification
        // the 2026-07 audit flagged on this exact path. Real dispatches
        // (200), result writebacks, and any error status still record.
        if isIdleWorkerCheckIn(path: path, statusCode: statusCode) { return false }
        if isSubmissionStatusPoll(method: method, path: path, statusCode: statusCode) { return false }
        return shouldAlwaysLogRequest(path: path)
    }

    /// The student result view polls `GET /api/v1/submissions/<id>` every two
    /// seconds for as long as its submission is pending (`Public/app.js`).
    /// During a deadline that is the highest-frequency request the server
    /// takes, and persisting a row for each turns a cheap read into a write at
    /// the moment the database is busiest — the same amplification already
    /// excluded for idle runner check-ins, arriving from the other side.
    ///
    /// Scoped to the bare status route: `/results`, `/download` and the
    /// collection route keep recording. Errors record too, so a poll that
    /// starts failing or slowing into 5xx stays visible.
    private func isSubmissionStatusPoll(method: String, path: String, statusCode: Int) -> Bool {
        guard method == "GET", statusCode < 400 else { return false }
        let prefix = "/api/v1/submissions/"
        guard path.hasPrefix(prefix) else { return false }
        let remainder = path.dropFirst(prefix.count)
        return !remainder.isEmpty && !remainder.contains("/")
    }

    private func isIdleWorkerCheckIn(path: String, statusCode: Int) -> Bool {
        if path == "/api/v1/worker/request" { return statusCode == 204 }
        if path == "/api/v1/worker/heartbeat" { return statusCode < 400 }
        return false
    }

    private func shouldAlwaysLogRequest(path: String) -> Bool {
        path.hasPrefix("/api/") || path.hasPrefix("/submissions/") || path.hasPrefix("/testsetups/")
    }
}
