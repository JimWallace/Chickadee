// APIServer/MCP/Admin/Tools/GetMetricsSnapshotTool.swift
//
// Read tool: the operational metrics snapshot — runner loads/liveness, peak
// queue depth, recent job status counts, queue-wait/execution duration
// summaries, compatibility counters, and the in-memory hot-path request
// counts.  Wraps the same PII-free aggregate the
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
        + "compatibility counters, over the server's recent window. Also hotPaths: in-memory "
        + "request counts and latency (p50/p95/p99/max, peak per minute) for the runner poll, "
        + "runner heartbeat and submission status poll, which get_request_metrics does not "
        + "record on success; counted per process since countingSince and over the last 60 "
        + "minutes. Use it to diagnose runner health, throughput, queue pressure, and hot-path "
        + "load. Read-only; aggregates only — no student, submission, course, or assignment "
        + "identifiers."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        return try await context.request.application.diagnostics.metricsSnapshot(req: context.request)
    }
}
