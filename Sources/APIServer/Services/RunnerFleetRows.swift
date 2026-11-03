// APIServer/Services/RunnerFleetRows.swift
//
// The runner-fleet rows and the job-timing arithmetic that the admin runners
// page and the admin-diagnostics MCP tools share. Moved out of
// Routes/Web/AdminRoutes+Runners.swift (#2496), so the MCP tools do not
// depend on the web route layer.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

private struct WorkerStatusCountRow: Decodable {
    let workerID: String?
    let status: String?
    let total: Int

    enum CodingKeys: String, CodingKey {
        case workerID = "worker_id"
        case status
        case total
    }
}

func makeWorkerRows(req: Request) async throws -> [AdminWorkerRow] {
    let workers = await req.application.workerActivityStore.snapshotsSortedByRecent()

    // Grouped COUNT by (worker_id, status), limited to the runners in the
    // activity store and to the three statuses the rows show. A row for any
    // other worker or status is never read, so the query reads the
    // (worker_id, status) index for the known runners only, not the whole
    // submissions table, which grows without bound across terms (#2777).
    let runnerIDs = workers.map(\.workerID).filter { !$0.isEmpty }
    let (assignedByWorkerID, processedByWorkerID) = try await workerJobCounts(
        workerIDs: runnerIDs, on: req.db)

    // Fetch rolling averages (last 50 jobs per runner) via the diagnostics service.
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
            lastActive: iso8601String(snapshot.lastActive),
            assignedJobs: assigned,
            jobsProcessed: processed,
            avgExecutionMs: avgExec,
            avgQueueWaitMs: avgWait,
            avgExecutionFormatted: avgExec.map(formatMs),
            avgQueueWaitFormatted: avgWait.map(formatMs),
            isOffline: RunnerStaleness.isOffline(lastActive: snapshot.lastActive)
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

/// Per worker in `workerIDs`: the jobs it holds now (`assigned`) and the jobs
/// it finished (`complete` or `failed`). A worker with no such job is absent
/// from both maps.
func workerJobCounts(
    workerIDs: [String], on db: any Database
) async throws -> (assigned: [String: Int], processed: [String: Int]) {
    var assigned: [String: Int] = [:]
    var processed: [String: Int] = [:]
    guard !workerIDs.isEmpty else { return (assigned, processed) }
    let assignedStatus = SubmissionStatus.assigned.rawValue
    let processedStatuses = [SubmissionStatus.complete.rawValue, SubmissionStatus.failed.rawValue]
    func tally(workerID: String?, status: String?, total: Int) {
        guard let workerID, !workerID.isEmpty else { return }
        if status == assignedStatus {
            assigned[workerID, default: 0] += total
        } else if let status, processedStatuses.contains(status) {
            processed[workerID, default: 0] += total
        }
    }
    if let sql = db as? (any SQLDatabase) {
        let counts = try await sql.select()
            .column("worker_id")
            .column("status")
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "total")
            .from(APISubmission.schema)
            .where("worker_id", .in, workerIDs)
            .where("status", .in, [assignedStatus] + processedStatuses)
            .groupBy("worker_id")
            .groupBy("status")
            .all(decoding: WorkerStatusCountRow.self)
        for row in counts {
            tally(workerID: row.workerID, status: row.status, total: row.total)
        }
    } else {
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$workerID ~~ workerIDs)
            .all()
        for submission in submissions {
            tally(workerID: submission.workerID, status: submission.status, total: 1)
        }
    }
    return (assigned, processed)
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
    if kb < 1024 { return String(cFormat: "%.0f KB", kb) }
    let mb = kb / 1024
    if mb < 100 { return String(cFormat: "%.1f MB", mb) }
    if mb < 1024 { return String(cFormat: "%.0f MB", mb) }
    let gb = mb / 1024
    return String(cFormat: "%.1f GB", gb)
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
    ].compactMap(\.self)

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
    let present = values.compactMap(\.self)
    guard !present.isEmpty else { return nil }
    return present.reduce(0, +)
}

struct AdminWorkerRow: Content {
    let workerID: String
    let hostname: String
    let runnerVersion: String
    let maxConcurrentJobs: Int
    let lastActive: String
    let assignedJobs: Int
    let jobsProcessed: Int
    let avgExecutionMs: Int?
    let avgQueueWaitMs: Int?
    /// Human-readable form of `avgExecutionMs` (e.g. "14s", "850ms"), or nil.
    let avgExecutionFormatted: String?
    /// Human-readable form of `avgQueueWaitMs` (e.g. "3s", "200ms"), or nil.
    let avgQueueWaitFormatted: String?
    /// True when the runner has not checked in within
    /// `RunnerStaleness.offlineAfter`. Computed on the server so the first
    /// render and every background refresh agree — the client-side copy this
    /// replaced only ran during a poll, so a freshly loaded dashboard showed
    /// no offline badges at all until the first tick.
    let isOffline: Bool
}
