// APIServer/MCP/Admin/Tools/GetRequestMetricsTool.swift
//
// Read tool: HTTP request-timing aggregates over a window — total requests,
// counts by status class (2xx/3xx/4xx/5xx), an overall duration summary, and
// the slowest routes (by P95).  Reads request_metrics (captured for /api/*,
// /submissions/*, /testsetups/* — and everything under verbose timing).
//
// PII boundary: request_metrics carries no user_id, but a concrete path can
// embed a submission/test-setup id (e.g. /submissions/sub_ab12). This tool
// NORMALISES those id-like path segments to ":id" before aggregating, so it
// reports per-route shapes and never a row-level identifier.

import Core
import Fluent
import Vapor

struct GetRequestMetricsTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Look-back window in hours (default 24; clamped 1…720).
        var windowHours: Int?
        /// Optional path prefix filter (e.g. "/api/").
        var pathPrefix: String?
        /// Max slowest-routes rows to return (default 15; clamped 1…100).
        var limit: Int?
    }

    struct StatusClassCount: Encodable, Sendable {
        let statusClass: String
        let count: Int
    }

    struct RouteStat: Encodable, Sendable {
        /// Normalised "<METHOD> <path>" with id-like segments collapsed to ":id".
        let route: String
        let count: Int
        let errorCount: Int
        let p95Ms: Int?
        let maxMs: Int
    }

    struct Output: Encodable, Sendable {
        let windowHours: Int
        let total: Int
        let byStatusClass: [StatusClassCount]
        let overall: DurationSummaryResponse
        let slowestRoutes: [RouteStat]
    }

    static let name = "get_request_metrics"
    static let description =
        "HTTP request-timing aggregates over a window: total requests, counts by status class "
        + "(2xx/3xx/4xx/5xx), an overall duration summary (avg/p50/p95), and the slowest routes by "
        + "P95 (with request count, error count, and max duration). Optional windowHours (default 24, "
        + "max 720), pathPrefix filter, and limit. Captured for /api/*, /submissions/*, /testsetups/* "
        + "(all paths under verbose timing). Read-only; id-like path segments are normalized to \":id\" "
        + "so only per-route shapes are reported — never a row-level identifier."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "windowHours": .object([
                "type": .string("integer"),
                "description": .string("Look-back window in hours (default 24, max 720)."),
            ]),
            "pathPrefix": .object([
                "type": .string("string"),
                "description": .string("Optional path prefix filter, e.g. \"/api/\"."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max slowest-routes rows (default 15, max 100)."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let windowHours = min(max(input.windowHours ?? 24, 1), 720)
        let limit = min(max(input.limit ?? 15, 1), 100)
        let since = Date().addingTimeInterval(Double(-windowHours) * 3600)

        var query = APIRequestMetric.query(on: context.db).filter(\.$finishedAt >= since)
        let prefix = input.pathPrefix.flatMap { $0.isEmpty ? nil : $0 }
        if let prefix {
            // Narrow at the DB with a substring match, then refine to a true
            // prefix in Swift (Fluent has no portable prefix operator).
            query = query.filter(\.$path ~~ prefix)
        }
        var rows = try await query.all()
        if let prefix {
            rows = rows.filter { $0.path.hasPrefix(prefix) }
        }

        var statusClasses: [String: Int] = [:]
        var durationsByRoute: [String: [Int]] = [:]
        var errorsByRoute: [String: Int] = [:]
        var maxByRoute: [String: Int] = [:]
        var allDurations: [Int] = []
        for row in rows {
            statusClasses[Self.statusClass(row.statusCode), default: 0] += 1
            let route = "\(row.method) \(Self.normalizePath(row.path))"
            durationsByRoute[route, default: []].append(row.durationMs)
            maxByRoute[route] = max(maxByRoute[route] ?? 0, row.durationMs)
            if row.statusCode >= 400 { errorsByRoute[route, default: 0] += 1 }
            allDurations.append(row.durationMs)
        }

        let diagnostics = context.request.application.diagnostics
        let slowestRoutes = durationsByRoute.map { route, durations in
            RouteStat(
                route: route,
                count: durations.count,
                errorCount: errorsByRoute[route, default: 0],
                p95Ms: diagnostics.durationSummary(for: durations).p95Ms,
                maxMs: maxByRoute[route] ?? 0)
        }
        .sorted { ($0.p95Ms ?? 0, $0.maxMs) > ($1.p95Ms ?? 0, $1.maxMs) }
        .prefix(limit)

        return Output(
            windowHours: windowHours,
            total: rows.count,
            byStatusClass: statusClasses.map { StatusClassCount(statusClass: $0.key, count: $0.value) }
                .sorted { $0.statusClass < $1.statusClass },
            overall: diagnostics.durationSummary(for: allDurations),
            slowestRoutes: Array(slowestRoutes))
    }

    /// "2xx" / "3xx" / "4xx" / "5xx" / "other" for a numeric status code.
    static func statusClass(_ code: Int) -> String {
        switch code {
        case 200..<300: return "2xx"
        case 300..<400: return "3xx"
        case 400..<500: return "4xx"
        case 500..<600: return "5xx"
        default: return "other"
        }
    }

    /// Collapse id-like path segments to ":id" so per-route aggregation never
    /// surfaces a concrete submission/test-setup id from the path.
    static func normalizePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in isIdentifierSegment(String(segment)) ? ":id" : String(segment) }
            .joined(separator: "/")
    }

    private static func isIdentifierSegment(_ segment: String) -> Bool {
        if segment.isEmpty { return false }
        for prefix in ["sub_", "setup_", "res_", "job_"] where segment.hasPrefix(prefix) {
            return true
        }
        let lower = segment.lowercased()
        // UUID, long hex, or long numeric run — all stand in for a concrete id.
        if lower.count >= 32, lower.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        if segment.count >= 6, segment.allSatisfy(\.isNumber) { return true }
        return false
    }
}
