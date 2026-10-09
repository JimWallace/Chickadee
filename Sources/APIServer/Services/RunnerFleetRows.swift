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

    // Grouped COUNT by (worker_id, status) rather than loading the entire
    // submissions table into memory and tallying per worker in Swift — the
    // submissions table grows without bound across terms.
    var assignedByWorkerID: [String: Int] = [:]
    var processedByWorkerID: [String: Int] = [:]
    if let sql = req.db as? SQLDatabase {
        let counts = try await sql.select()
            .column("worker_id")
            .column("status")
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "total")
            .from("submissions")
            .groupBy("worker_id")
            .groupBy("status")
            .all(decoding: WorkerStatusCountRow.self)
        for row in counts {
            guard let workerID = row.workerID, !workerID.isEmpty else { continue }
            switch row.status {
            case SubmissionStatus.assigned.rawValue:
                assignedByWorkerID[workerID, default: 0] += row.total
            case SubmissionStatus.complete.rawValue, SubmissionStatus.failed.rawValue:
                processedByWorkerID[workerID, default: 0] += row.total
            default:
                break
            }
        }
    } else {
        let submissions = try await APISubmission.query(on: req.db).all()
        for submission in submissions {
            guard let workerID = submission.workerID, !workerID.isEmpty else { continue }
            if submission.statusValue == .assigned {
                assignedByWorkerID[workerID, default: 0] += 1
            }
            if submission.statusValue == .complete || submission.statusValue == .failed {
                processedByWorkerID[workerID, default: 0] += 1
            }
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
