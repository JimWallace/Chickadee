// APIServer/Routes/Web/AdminRoutes+Runners.swift
//
// Admin runner / worker dashboard routes and supporting helpers.
// All routes are registered in AdminRoutes.boot().

import Core
import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    // MARK: - GET /admin/runners

    @Sendable
    func runners(req: Request) async throws -> [AdminWorkerRow] {
        try await makeWorkerRows(req: req)
    }

    // MARK: - GET /admin/workers (compat alias)

    @Sendable
    func workers(req: Request) async throws -> [AdminWorkerRow] {
        try await makeWorkerRows(req: req)
    }

    // MARK: - GET /admin/runners/:runnerID

    @Sendable
    func runnerDetail(req: Request) async throws -> View {
        guard let runnerID = req.parameters.get("runnerID"), !runnerID.isEmpty else {
            throw Abort(.notFound)
        }

        let worker = try await resolveWorkerRow(req: req, runnerID: runnerID)
        let runnerProfile = try? await req.application.runnerProfiles.profile(for: runnerID, on: req.db)

        let snapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .descending)
            .limit(50)
            .all()

        let recentJobs = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$completedAt, .descending)
            .limit(50)
            .all()

        let usernameByID = try await fetchUsernames(req: req, jobs: recentJobs)
        let firstSeenAt = try await fetchFirstSeenAt(req: req, runnerID: runnerID)
        let statusCounts = countStatuses(in: recentJobs)
        let snapshotRows = snapshots.map(snapshotRow(for:))
        let jobRows = recentJobs.map { jobRow(for: $0, usernameByID: usernameByID) }
        let summary = makeRunnerSummary(worker: worker, recentJobs: recentJobs, statusCounts: statusCounts)
        let tags = makeRunnerTags(profile: runnerProfile)

        return try await req.view.render(
            "admin-runner",
            AdminRunnerDetailContext(
                currentUser: req.currentUserContext,
                runner: worker,
                tags: tags,
                summary: summary,
                recentJobs: jobRows,
                snapshots: snapshotRows,
                firstSeenAt: firstSeenAt
            ))
    }

    // MARK: - runnerDetail helpers

    private func resolveWorkerRow(req: Request, runnerID: String) async throws -> AdminWorkerRow {
        let workerRows = try await makeWorkerRows(req: req)
        if let found = workerRows.first(where: { $0.workerID == runnerID }) {
            return found
        }
        // Runner was pruned from the in-memory store (offline >60 min).
        // Reconstruct a minimal row from the most recent DB snapshot so
        // the detail page can still render historical data instead of 404.
        guard
            let latestSnapshot = try await RunnerSnapshot.query(on: req.db)
                .filter(\.$runnerID == runnerID)
                .sort(\.$recordedAt, .descending)
                .first()
        else {
            throw Abort(.notFound)
        }
        let iso = ISO8601DateFormatter()
        let processedCount = try await APISubmission.query(on: req.db)
            .filter(\.$workerID == runnerID)
            .filter(\.$status ~~ ["complete", "failed"])
            .count()
        let avgData = try? await req.application.diagnostics.rollingAverages(
            for: [runnerID], sampleSize: 50, on: req.db
        )
        let avg = avgData?[runnerID]
        return AdminWorkerRow(
            workerID: runnerID,
            hostname: latestSnapshot.hostname ?? "",
            runnerVersion: latestSnapshot.runnerVersion ?? "",
            maxConcurrentJobs: latestSnapshot.maxJobs,
            lastActive: iso.string(from: latestSnapshot.recordedAt),
            assignedJobs: 0,
            jobsProcessed: processedCount,
            avgExecutionMs: avg?.avgExecutionMs,
            avgQueueWaitMs: avg?.avgQueueWaitMs,
            avgExecutionFormatted: avg?.avgExecutionMs.map(formatMs),
            avgQueueWaitFormatted: avg?.avgQueueWaitMs.map(formatMs)
        )
    }

    private func fetchUsernames(req: Request, jobs: [JobExecutionMetric]) async throws -> [UUID: String] {
        let userIDs = Array(Set(jobs.compactMap { $0.userID }))
        let users =
            userIDs.isEmpty
            ? []
            : try await APIUser.query(on: req.db)
                .filter(\.$id ~~ userIDs)
                .all()
        return Dictionary(
            uniqueKeysWithValues: users.compactMap {
                guard let id = $0.id else { return nil }
                return (id, $0.username)
            })
    }

    private func fetchFirstSeenAt(req: Request, runnerID: String) async throws -> String? {
        let firstSnapshot = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .ascending)
            .first()
        return firstSnapshot.map { iso8601String($0.recordedAt) }
    }

    private func countStatuses(in jobs: [JobExecutionMetric]) -> [String: Int] {
        var statusCounts: [String: Int] = [:]
        for job in jobs {
            guard let status = job.finalStatus else { continue }
            statusCounts[status, default: 0] += 1
        }
        return statusCounts
    }

    private func snapshotRow(for snapshot: RunnerSnapshot) -> AdminRunnerSnapshotRow {
        let utilizationPercent =
            snapshot.maxJobs > 0
            ? Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded())
            : 0
        return AdminRunnerSnapshotRow(
            recordedAt: iso8601String(snapshot.recordedAt),
            activeJobs: snapshot.activeJobs,
            maxJobs: snapshot.maxJobs,
            activeJobsLabel: "\(snapshot.activeJobs) / \(snapshot.maxJobs)",
            utilizationPercent: utilizationPercent,
            lastPollAt: snapshot.lastPollAt.map(iso8601String)
        )
    }

    private func jobRow(
        for metric: JobExecutionMetric,
        usernameByID: [UUID: String]
    ) -> AdminRunnerJobRow {
        AdminRunnerJobRow(
            submissionID: metric.submissionID,
            assignmentID: metric.assignmentID?.uuidString,
            username: metric.userID.flatMap { usernameByID[$0] },
            finalStatus: metric.finalStatus ?? "unknown",
            queueWaitMs: metric.queueWaitMs,
            executionMs: metric.executionMs,
            queueWaitFormatted: metric.queueWaitMs.map(formatMs),
            executionFormatted: metric.executionMs.map(formatMs),
            totalProcessingMs: metric.totalProcessingMs,
            totalProcessingFormatted: metric.totalProcessingMs.map(formatMs),
            workdirPeakBytes: metric.workdirPeakBytes,
            workdirPeakFormatted: metric.workdirPeakBytes.map(formatBytes),
            completedAt: metric.completedAt.map(iso8601String)
        )
    }

    private func makeRunnerSummary(
        worker: AdminWorkerRow,
        recentJobs: [JobExecutionMetric],
        statusCounts: [String: Int]
    ) -> AdminRunnerSummary {
        let overheadSamples = recentJobs.compactMap { overheadMs(for: $0) }
        let stageBreakdowns = recentJobs.map(stageBreakdown(for:))
        let cacheFlagged = recentJobs.compactMap { $0.testSetupCacheHit }
        let cacheHitRateFormatted: String? = {
            guard !cacheFlagged.isEmpty else { return nil }
            let hits = cacheFlagged.filter { $0 }.count
            let pct = Int((Double(hits) / Double(cacheFlagged.count) * 100).rounded())
            return "\(pct)% (\(hits)/\(cacheFlagged.count))"
        }()

        return AdminRunnerSummary(
            activeJobs: worker.assignedJobs,
            maxJobs: worker.maxConcurrentJobs,
            jobsProcessed: worker.jobsProcessed,
            avgExecutionFormatted: worker.avgExecutionFormatted,
            avgQueueWaitFormatted: worker.avgQueueWaitFormatted,
            avgOverheadFormatted: average(overheadSamples).map(formatMs),
            avgCacheAcquireFormatted: average(stageBreakdowns.compactMap { $0?.cacheAcquireMs }).map(formatMs),
            avgDownloadFormatted: average(stageBreakdowns.compactMap { $0?.downloadMs }).map(formatMs),
            avgPrepFormatted: average(stageBreakdowns.compactMap { $0?.prepMs }).map(formatMs),
            cacheHitRateFormatted: cacheHitRateFormatted,
            passedCount: statusCounts["passed", default: 0],
            failedCount: statusCounts["failed", default: 0],
            errorCount: statusCounts["error", default: 0],
            timeoutCount: statusCounts["timeout", default: 0]
        )
    }

    private func makeRunnerTags(profile: RunnerProfile?) -> [String] {
        guard let profile = profile?.capabilityProfile else { return [] }
        var values: [String] = []
        if !profile.platform.isEmpty {
            values.append(profile.platform)
        }
        if !profile.architecture.isEmpty {
            values.append(profile.architecture)
        }
        values.append(contentsOf: profile.languageVersions.map { "\($0.language) \($0.version)" })
        values.append(contentsOf: profile.capabilities.map(\.name))
        return values
    }
}

// MARK: - File-private worker-row + formatting helpers

func makeWorkerRows(req: Request) async throws -> [AdminWorkerRow] {
    let iso = ISO8601DateFormatter()
    let workers = await req.application.workerActivityStore.snapshotsSortedByRecent()
    let submissions = try await APISubmission.query(on: req.db).all()

    var assignedByWorkerID: [String: Int] = [:]
    var processedByWorkerID: [String: Int] = [:]
    for submission in submissions {
        guard let workerID = submission.workerID, !workerID.isEmpty else { continue }
        if submission.status == "assigned" {
            assignedByWorkerID[workerID, default: 0] += 1
        }
        if submission.status == "complete" || submission.status == "failed" {
            processedByWorkerID[workerID, default: 0] += 1
        }
    }

    // Fetch rolling averages (last 50 jobs per runner) via the diagnostics service.
    let runnerIDs = workers.map(\.workerID).filter { !$0.isEmpty }
    let averages =
        (try? await req.application.diagnostics.rollingAverages(
            for: runnerIDs, sampleSize: 50, on: req.db
        )) ?? [:]

    return workers.map { snapshot in
        let assigned = assignedByWorkerID[snapshot.workerID, default: 0]
        let processed = processedByWorkerID[snapshot.workerID, default: 0]
        let avg = averages[snapshot.workerID]
        let avgExec = avg?.avgExecutionMs
        let avgWait = avg?.avgQueueWaitMs
        return AdminWorkerRow(
            workerID: snapshot.workerID,
            hostname: snapshot.hostname,
            runnerVersion: snapshot.runnerVersion,
            maxConcurrentJobs: snapshot.maxConcurrentJobs,
            lastActive: iso.string(from: snapshot.lastActive),
            assignedJobs: assigned,
            jobsProcessed: processed,
            avgExecutionMs: avgExec,
            avgQueueWaitMs: avgWait,
            avgExecutionFormatted: avgExec.map(formatMs),
            avgQueueWaitFormatted: avgWait.map(formatMs)
        )
    }
    .sorted { lhs, rhs in
        let compare = lhs.workerID.localizedStandardCompare(rhs.workerID)
        if compare == .orderedSame {
            return lhs.hostname.localizedStandardCompare(rhs.hostname) == .orderedAscending
        }
        return compare == .orderedAscending
    }
}

func formatMs(_ ms: Int) -> String {
    if ms < 1000 {
        return "\(ms)ms"
    }

    let totalSeconds = ms / 1000
    if totalSeconds < 60 {
        return "\(totalSeconds)s"
    }

    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        if seconds == 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(hours)h \(minutes)m"
    }

    return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.0f KB", kb) }
    let mb = kb / 1024
    if mb < 100 { return String(format: "%.1f MB", mb) }
    if mb < 1024 { return String(format: "%.0f MB", mb) }
    let gb = mb / 1024
    return String(format: "%.1f GB", gb)
}

func overheadMs(for metric: JobExecutionMetric) -> Int? {
    guard
        let total = metric.totalProcessingMs,
        let queueWait = metric.queueWaitMs,
        let execution = metric.executionMs
    else {
        return nil
    }

    return max(0, total - queueWait - execution)
}

struct StageBreakdown {
    let cacheAcquireMs: Int?
    let downloadMs: Int?
    let prepMs: Int?
    let makeMs: Int?
    let formatted: String?
}

func stageBreakdown(for metric: JobExecutionMetric) -> StageBreakdown? {
    let cacheAcquireMs = metric.testSetupAcquireMs
    let downloadMs = metric.submissionDownloadMs
    let prepMs = sum([
        metric.workdirSetupMs,
        metric.submissionDirSetupMs,
        metric.submissionUnpackMs,
        metric.starterCleanupMs,
        metric.submissionPrepareMs,
        metric.runtimeHelperSetupMs,
    ])
    let makeMs = metric.makeStepMs

    let parts = [
        cacheAcquireMs.map { "cache \(formatMs($0))" },
        downloadMs.map { "dl \(formatMs($0))" },
        prepMs.map { "prep \(formatMs($0))" },
        makeMs.map { "make \(formatMs($0))" },
    ].compactMap { $0 }

    guard !parts.isEmpty else { return nil }
    return StageBreakdown(
        cacheAcquireMs: cacheAcquireMs,
        downloadMs: downloadMs,
        prepMs: prepMs,
        makeMs: makeMs,
        formatted: parts.joined(separator: " · ")
    )
}

func average(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / values.count
}

func sum(_ values: [Int?]) -> Int? {
    let present = values.compactMap { $0 }
    guard !present.isEmpty else { return nil }
    return present.reduce(0, +)
}

func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
