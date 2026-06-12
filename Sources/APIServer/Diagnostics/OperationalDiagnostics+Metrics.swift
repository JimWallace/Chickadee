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

        let runnerSnapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$recordedAt >= windowStart)
            .sort(\.$recordedAt, .ascending)
            .all()
        let activeSnapshots = await req.application.workerActivityStore.snapshotsSortedByRecent()
            .filter { now.timeIntervalSince($0.lastActive) <= configuration.activeRunnerWindowSeconds }
        let recentMetrics = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$completedAt >= windowStart)
            .all()
        let maxQueueDepth = try await maxQueueDepthSince(windowStart: windowStart, now: now, on: req.db)
        let peakLoadSnapshot = peakLoad(from: runnerSnapshots)

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
            peakUtilizationPercent: peakUtilizationPercent(from: runnerSnapshots),
            maxLoadActiveJobs: peakLoadSnapshot?.activeJobs,
            maxLoadCapacity: peakLoadSnapshot?.maxJobs,
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

        let runnerSnapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$recordedAt >= window.windowStart)
            .sort(\.$recordedAt, .ascending)
            .all()

        let requestMetrics = try await APIRequestMetric.query(on: req.db)
            .filter(\.$finishedAt >= window.windowStart)
            .sort(\.$finishedAt, .ascending)
            .all()

        let jobMetrics = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$completedAt >= window.windowStart)
            .sort(\.$completedAt, .ascending)
            .all()

        let runners = MetricBucketAccumulators.accumulateRunnerSnapshots(runnerSnapshots, window: window)
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
        guard shouldCaptureRequest(path: metric.path) else { return }

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

    private func shouldCaptureRequest(path: String) -> Bool {
        configuration.verboseRequestTiming || shouldAlwaysLogRequest(path: path)
    }

    private func shouldAlwaysLogRequest(path: String) -> Bool {
        path.hasPrefix("/api/") || path.hasPrefix("/submissions/") || path.hasPrefix("/testsetups/")
    }
}
