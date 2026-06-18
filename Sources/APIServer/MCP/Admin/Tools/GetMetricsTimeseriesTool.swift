// APIServer/MCP/Admin/Tools/GetMetricsTimeseriesTool.swift
//
// Read tool: the flexible-window operational time-series — per-bucket runner
// utilisation, request count + P95 latency, completed jobs, test status counts,
// and queue-wait/execution P95 over an arbitrary window/bucket size.  Wraps the
// same builder the admin dashboard's /admin/metrics/timeseries endpoint serves
// (`metricsTimeSeriesSnapshot`): bucketed aggregates only — no user, submission,
// course, or assignment identifiers.  Where get_metrics_card_series is fixed to
// the dashboard's three sparkline windows, this lets an agent zoom into a
// specific window (e.g. "the last 6 hours in 15-minute buckets") to correlate a
// latency or error spike.

import Core
import Vapor

struct GetMetricsTimeseriesTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Trailing window in hours (clamped server-side; defaults to the
        /// configured recent-metrics window, typically 24).
        var hours: Int?
        /// Bucket width in minutes (clamped server-side to a sane range).
        var bucketMinutes: Int?
    }

    /// The existing dashboard time-series payload, reused verbatim — bucketed
    /// aggregates only, no row-level identifiers.
    typealias Output = InternalMetricsTimeSeriesResponse

    static let name = "get_metrics_timeseries"
    static let description =
        "Flexible-window operational time-series: per-bucket avg/max runner utilization, active "
        + "runners, request count + P95 latency, completed jobs, test status counts (passed/failed/"
        + "error/timeout), and queue-wait/execution P95. Optional hours (trailing window) and "
        + "bucketMinutes (bucket width) — both clamped server-side; omit for the configured default "
        + "(~24h). Unlike get_metrics_card_series (fixed 24h/7d/30d sparkline windows), this zooms "
        + "into an arbitrary window to correlate a latency or error spike, and it's the only tool that "
        + "surfaces HTTP request latency. Read-only; bucketed aggregates only — no student, "
        + "submission, course, or assignment identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "hours": .object([
                "type": .string("integer"),
                "description": .string("Trailing window in hours (clamped server-side)."),
            ]),
            "bucketMinutes": .object([
                "type": .string("integer"),
                "description": .string("Bucket width in minutes (clamped server-side)."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)
        return try await context.request.application.diagnostics.metricsTimeSeriesSnapshot(
            req: context.request, hours: input.hours, bucketMinutes: input.bucketMinutes)
    }
}
