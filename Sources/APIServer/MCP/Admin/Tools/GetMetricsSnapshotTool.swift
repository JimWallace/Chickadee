// APIServer/MCP/Admin/Tools/GetMetricsSnapshotTool.swift
//
// Read tool: the operational metrics snapshot — runner loads/liveness, peak
// queue depth, recent job status counts, queue-wait/execution duration
// summaries, and compatibility counters.  Wraps the same PII-free aggregate the
// admin dashboard's /admin/metrics endpoint serves (InternalMetricsResponse):
// counts, percentiles, and per-runner operational fields only — no user,
// submission, course, or assignment identifiers.

import Core
import Vapor

struct GetMetricsSnapshotTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    /// The existing dashboard aggregate, reused verbatim — already audited as
    /// PII-free (no row-level student identifiers).
    typealias Output = InternalMetricsResponse

    static let name = "get_metrics_snapshot"
    static let description =
        "Operational metrics snapshot: per-runner load and liveness (active/max jobs, capacity, "
        + "last poll/heartbeat), peak queue depth, recent job status counts (passed/failed/error/"
        + "timeout), queue-wait and execution duration summaries (avg/p50/p95), and runner-"
        + "compatibility counters, over the server's recent window. Use it to diagnose runner "
        + "health, throughput, and queue pressure. Read-only; aggregates only — no student, "
        + "submission, course, or assignment identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)
        return try await context.request.application.diagnostics.metricsSnapshot(req: context.request)
    }
}
