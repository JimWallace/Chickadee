// APIServer/MCP/Admin/Tools/GetRunnerDetailTool.swift
//
// Read tool: one runner's detail — identity, capability profile (platform /
// architecture / language versions / capabilities), an aggregate timing
// breakdown over its recent jobs (avg execution / queue-wait / overhead /
// per-stage, plus cache-hit rate and status counts), and its recent load
// snapshots.  Backs the /admin/runners/:id page.
//
// PII boundary (code allowlist — the shipped guarantee): the recent-jobs source
// (job_execution_metrics) carries user_id / submission_id, so this tool exposes
// only the AGGREGATE summary computed over those rows — never the row-level job
// records the web page shows (which carry username + submission id). Snapshots
// (runner_snapshots) are PII-free and listed as-is.

import Core
import Fluent
import Vapor

struct GetRunnerDetailTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// The runner id (as listed by list_runners / get_metrics_snapshot).
        var runnerID: String
        /// How many recent jobs to aggregate the timing summary over
        /// (default 50; clamped 1…200).
        var sampleSize: Int?
    }

    struct TimingSummary: Encodable, Sendable {
        let sampleSize: Int
        let avgExecutionMs: Int?
        let avgQueueWaitMs: Int?
        let avgOverheadMs: Int?
        let avgCacheAcquireMs: Int?
        let avgDownloadMs: Int?
        let avgPrepMs: Int?
        /// Cache-hit rate over recent jobs that reported a cache flag, as a
        /// percent; nil when no recent job reported one.
        let cacheHitRatePercent: Int?
        let cacheHitSamples: Int
        let passedCount: Int
        let failedCount: Int
        let errorCount: Int
        let timeoutCount: Int
    }

    struct SnapshotRow: Encodable, Sendable {
        let recordedAt: Date
        let activeJobs: Int
        let maxJobs: Int
        let utilizationPercent: Int
        let lastPollAt: Date?
    }

    struct Output: Encodable, Sendable {
        let runnerID: String
        let hostname: String
        let runnerVersion: String
        let activeJobs: Int
        let maxConcurrentJobs: Int
        let jobsProcessed: Int
        let lastActive: String
        let firstSeenAt: Date?
        /// Capability tags: platform, architecture, "<language> <version>", and
        /// capability names — the same set the assignment-compatibility matcher
        /// checks against.
        let capabilities: [String]
        let timing: TimingSummary
        let recentSnapshots: [SnapshotRow]
    }

    static let name = "get_runner_detail"
    static let description =
        "One runner's detail: identity (hostname, version, load, all-time jobs), its capability "
        + "profile (platform / architecture / language versions / capabilities — what the "
        + "assignment-compatibility matcher checks), an aggregate timing breakdown over its recent "
        + "jobs (avg execution / queue-wait / overhead / cache-acquire / download / prep, cache-hit "
        + "rate, and passed/failed/error/timeout counts), and recent load snapshots. Use it to "
        + "diagnose why jobs are slow on a runner or why an assignment won't match it. Requires "
        + "runnerID (from list_runners). Read-only; aggregates only — the per-job rows the web page "
        + "shows (with username + submission id) are deliberately omitted."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "runnerID": .object([
                "type": .string("string"),
                "description": .string("Runner id, as listed by list_runners or get_metrics_snapshot."),
            ]),
            "sampleSize": .object([
                "type": .string("integer"),
                "description": .string("Recent jobs to aggregate the timing summary over (default 50, max 200)."),
            ]),
        ]),
        "required": .array([.string("runnerID")]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let runnerID = input.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runnerID.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "runnerID must not be empty.")
        }
        let sampleSize = min(max(input.sampleSize ?? 50, 1), 200)
        let db = context.db

        let identity = try await resolveIdentity(runnerID: runnerID, req: context.request)
        let profile = try? await context.request.application.runnerProfiles.profile(for: runnerID, on: db)

        let recentJobs = try await JobExecutionMetric.query(on: db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$completedAt, .descending)
            .limit(sampleSize)
            .all()
        let snapshots = try await RunnerSnapshot.query(on: db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .descending)
            .limit(50)
            .all()
        let firstSnapshot = try await RunnerSnapshot.query(on: db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .ascending)
            .first()

        return Output(
            runnerID: identity.workerID,
            hostname: identity.hostname,
            runnerVersion: identity.runnerVersion,
            activeJobs: identity.assignedJobs,
            maxConcurrentJobs: identity.maxConcurrentJobs,
            jobsProcessed: identity.jobsProcessed,
            lastActive: identity.lastActive,
            firstSeenAt: firstSnapshot?.recordedAt,
            capabilities: capabilityTags(profile: profile),
            timing: timingSummary(recentJobs: recentJobs),
            recentSnapshots: snapshots.map(snapshotRow(for:)))
    }

    /// Resolve the runner's identity row, falling back to its latest snapshot
    /// when it has aged out of the in-memory store (offline > 1h), mirroring the
    /// web detail page's reconstruction so historical runners still resolve.
    private func resolveIdentity(runnerID: String, req: Request) async throws -> AdminWorkerRow {
        let rows = try await makeWorkerRows(req: req)
        if let found = rows.first(where: { $0.workerID == runnerID }) {
            return found
        }
        guard
            let latest = try await RunnerSnapshot.query(on: req.db)
                .filter(\.$runnerID == runnerID)
                .sort(\.$recordedAt, .descending)
                .first()
        else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Unknown runner '\(runnerID)'.")
        }
        let processed = try await APISubmission.query(on: req.db)
            .filter(\.$workerID == runnerID)
            .filter(\.$status ~~ [SubmissionStatus.complete.rawValue, SubmissionStatus.failed.rawValue])
            .count()
        return AdminWorkerRow(
            workerID: runnerID,
            hostname: latest.hostname ?? "",
            runnerVersion: latest.runnerVersion ?? "",
            maxConcurrentJobs: latest.maxJobs,
            lastActive: iso8601String(latest.recordedAt),
            assignedJobs: 0,
            jobsProcessed: processed,
            avgExecutionMs: nil,
            avgQueueWaitMs: nil,
            avgExecutionFormatted: nil,
            avgQueueWaitFormatted: nil)
    }

    private func capabilityTags(profile: RunnerProfile?) -> [String] {
        guard let capability = profile?.capabilityProfile else { return [] }
        var values: [String] = []
        if !capability.platform.isEmpty { values.append(capability.platform) }
        if !capability.architecture.isEmpty { values.append(capability.architecture) }
        values.append(contentsOf: capability.languageVersions.map { "\($0.language) \($0.version)" })
        values.append(contentsOf: capability.capabilities.map(\.name))
        return values
    }

    private func timingSummary(recentJobs: [JobExecutionMetric]) -> TimingSummary {
        let stageBreakdowns = recentJobs.map(stageBreakdown(for:))
        let cacheFlagged = recentJobs.compactMap { $0.testSetupCacheHit }
        let cacheHits = cacheFlagged.filter { $0 }.count
        var statusCounts: [String: Int] = [:]
        for job in recentJobs {
            guard let status = job.finalStatus else { continue }
            statusCounts[status, default: 0] += 1
        }
        return TimingSummary(
            sampleSize: recentJobs.count,
            avgExecutionMs: average(recentJobs.compactMap { $0.executionMs }),
            avgQueueWaitMs: average(recentJobs.compactMap { $0.queueWaitMs }),
            avgOverheadMs: average(recentJobs.compactMap { overheadMs(for: $0) }),
            avgCacheAcquireMs: average(stageBreakdowns.compactMap { $0?.cacheAcquireMs }),
            avgDownloadMs: average(stageBreakdowns.compactMap { $0?.downloadMs }),
            avgPrepMs: average(stageBreakdowns.compactMap { $0?.prepMs }),
            cacheHitRatePercent: cacheFlagged.isEmpty
                ? nil : Int((Double(cacheHits) / Double(cacheFlagged.count) * 100).rounded()),
            cacheHitSamples: cacheFlagged.count,
            passedCount: statusCounts["passed", default: 0],
            failedCount: statusCounts["failed", default: 0],
            errorCount: statusCounts["error", default: 0],
            timeoutCount: statusCounts["timeout", default: 0])
    }

    private func snapshotRow(for snapshot: RunnerSnapshot) -> SnapshotRow {
        let utilization =
            snapshot.maxJobs > 0
            ? Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded())
            : 0
        return SnapshotRow(
            recordedAt: snapshot.recordedAt,
            activeJobs: snapshot.activeJobs,
            maxJobs: snapshot.maxJobs,
            utilizationPercent: utilization,
            lastPollAt: snapshot.lastPollAt)
    }
}
