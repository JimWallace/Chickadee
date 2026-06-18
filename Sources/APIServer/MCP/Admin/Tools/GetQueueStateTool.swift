// APIServer/MCP/Admin/Tools/GetQueueStateTool.swift
//
// Read tool: the current worker-queue state — pending depth, in-flight jobs,
// oldest-pending age, and the stuck-submission count (the 10-minute reaper's
// view).  This is the raw data *behind* the `queueBackedUp` health alert
// (get_health_alerts only reports whether it's firing) and the stuck-submission
// reaper, so an agent can see how backed up the queue is and whether jobs are
// orphaned on a crashed runner.  Counts and ages only — no identifiers.

import Core
import Fluent
import Vapor

struct GetQueueStateTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        let generatedAt: Date
        /// Worker-eligible pending submissions (validation + worker-graded
        /// students) — what the worker queue actually draws from.
        let pendingWorkerQueue: Int
        /// All pending submissions, including browser-graded ones the worker
        /// only picks up as a backstop.
        let pendingTotal: Int
        /// Submissions currently assigned or running on a runner.
        let inFlight: Int
        /// Age of the oldest pending submission, in seconds (nil if none pending).
        let oldestPendingAgeSeconds: Int?
        /// Submissions assigned to a runner but with no result past the stuck
        /// threshold — the reaper returns these to pending. A non-zero value
        /// usually means a runner crashed mid-job.
        let stuckAssignedCount: Int
        /// The reaper's stuck threshold, in seconds (currently 600 = 10 min).
        let stuckThresholdSeconds: Int
        /// Peak worker-queue depth over the recent window (matches the dashboard
        /// "Max Queue Depth" headline).
        let maxQueueDepthRecentWindow: Int
        let recentWindowHours: Int
    }

    static let name = "get_queue_state"
    static let description =
        "Current worker-queue state: pending depth (worker-eligible and total), in-flight jobs "
        + "(assigned/running), oldest-pending age in seconds, the stuck-submission count (assigned "
        + "with no result past the 10-minute reaper threshold — usually a crashed runner), and the "
        + "peak queue depth over the recent window. This is the raw data behind the queueBackedUp "
        + "health alert (get_health_alerts only says whether it's firing). Read-only; counts and ages "
        + "only — no identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

    private static let stuckThresholdSeconds = 600

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let db = context.db
        let diagnostics = context.request.application.diagnostics
        let now = Date()

        let pendingWorkerQueue = try await diagnostics.pendingQueueDepth(on: db)
        let inFlight = try await diagnostics.inFlightJobCount(on: db)

        let pendingTotal = try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .count()

        let oldestPending = try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .sort(\.$submittedAt, .ascending)
            .first()
        let oldestPendingAgeSeconds = oldestPending?.submittedAt.map {
            max(0, Int(now.timeIntervalSince($0)))
        }

        let stuckCutoff = now.addingTimeInterval(Double(-Self.stuckThresholdSeconds))
        let stuckAssignedCount = try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.assigned.rawValue)
            .filter(\.$assignedAt <= stuckCutoff)
            .count()

        let windowHours = max(1, diagnostics.configuration.recentMetricsWindowHours)
        let windowStart = now.addingTimeInterval(Double(-windowHours) * 3600)
        let maxQueueDepth = try await diagnostics.maxQueueDepthSince(
            windowStart: windowStart, now: now, on: db)

        return Output(
            generatedAt: now,
            pendingWorkerQueue: pendingWorkerQueue,
            pendingTotal: pendingTotal,
            inFlight: inFlight,
            oldestPendingAgeSeconds: oldestPendingAgeSeconds,
            stuckAssignedCount: stuckAssignedCount,
            stuckThresholdSeconds: Self.stuckThresholdSeconds,
            maxQueueDepthRecentWindow: maxQueueDepth,
            recentWindowHours: windowHours)
    }
}
