// APIServer/MCP/Admin/Tools/GetMetricsCardSeriesTool.swift
//
// Read tool: the time-series (sparkline) data behind the admin dashboard's five
// operational diagnostic cards — max queue depth, jobs processed, max load,
// p95 queue wait, and p95 execution — across all three selectable windows
// (24h / 7d / 30d).  Wraps the same builder the dashboard polls
// (`GET /admin/metrics/cards`, `metricsCardSeries`): per-bucket counts,
// percentiles, and utilisation only — no user, submission, course, or
// assignment identifiers.  This is the windowed series behind
// `get_metrics_snapshot`'s point-in-time numbers.

import Core
import Vapor

struct GetMetricsCardSeriesTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    /// The existing dashboard sparkline payload, reused verbatim — aggregate
    /// per-bucket series only, no row-level identifiers.
    typealias Output = MetricsCardSeriesResponse

    static let name = "get_metrics_card_series"
    static let description =
        "Time-series (sparkline) data behind the admin dashboard's five operational cards: per-bucket "
        + "max queue depth, jobs processed, max load (peak utilization %), p95 queue-wait ms, and p95 "
        + "execution ms. Returns every selectable window in one payload (24h = 24 hourly buckets, "
        + "7d = 28 six-hour buckets, 30d = 30 daily buckets), each with bucket labels, a headline, and "
        + "the per-bucket series (a nil entry means no data in that bucket). This is the windowed "
        + "series behind get_metrics_snapshot's point-in-time numbers — use it to see how throughput, "
        + "queue pressure, and latency trend over time. Read-only; aggregates only — no student, "
        + "submission, course, or assignment identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)
        return try await context.request.application.diagnostics.metricsCardSeries(on: context.db)
    }
}
