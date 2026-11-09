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
// reports per-route shapes and never a row-level identifier. The pathPrefix
// input is matched against the normalized routes too — a raw-path match would
// let a caller probe whether a specific concrete id occurred in the window
// (compliance audit F-3).

import Core
import Fluent
import SQLKit
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
    static let windowBound = MCPBoundedInt(default: 24, max: 720)
    static let limitBound = MCPBoundedInt(default: 15, max: 100)
    static let description =
        "HTTP request-timing aggregates over a window: total requests, counts by status class "
        + "(2xx/3xx/4xx/5xx), an overall duration summary (avg/p50/p95), and the slowest routes by "
        + "P95 (with request count, error count, and max duration). Optional windowHours "
        + "\(windowBound.rangeText), pathPrefix filter, and limit. Captured for /api/*, /submissions/*, /testsetups/* "
        + "(all paths under verbose timing). Without verbose timing, idle runner polls (204), runner heartbeats and "
        + "successful submission status polls are not recorded here; get_metrics_snapshot "
        + "reports them as hotPaths. Read-only; id-like path segments are normalized to \":id\" "
        + "so only per-route shapes are reported — never a row-level identifier. The pathPrefix filter "
        + "is matched against the normalized route (a concrete id in the prefix collapses to :id), so "
        + "it cannot probe for a specific submission or setup."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "windowHours": Self.windowBound.property("Look-back window in hours"),
            "pathPrefix": .object([
                "type": .string("string"),
                "description": .string("Optional path prefix filter, e.g. \"/api/\"."),
            ]),
            "limit": Self.limitBound.property("Max slowest-routes rows"),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        let windowHours = Self.windowBound.resolve(input.windowHours)
        let limit = Self.limitBound.resolve(input.limit)
        let since = Date().addingTimeInterval(Double(-windowHours) * 3600)

        // Grouped in the database: identical (method, path, status, duration)
        // rows arrive as one row with a count. The window holds every
        // recorded request for up to 30 days, and loading each as a full row
        // was the cost of this tool. The weights keep every percentile exact.
        guard let sql = context.db as? (any SQLDatabase) else {
            throw MCPToolError.executionFailed(detail: "request metrics need a SQL database")
        }
        var groups = try await sql.select()
            .column("method").column("path").column("status_code").column("duration_ms")
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "n")
            .from(APIRequestMetric.schema)
            .where("finished_at", .greaterThanOrEqual, SQLBind(since))
            .groupBy("method").groupBy("path").groupBy("status_code").groupBy("duration_ms")
            .all(decoding: RequestGroup.self)
        // The prefix is normalized and matched against NORMALIZED routes, so a
        // concrete submission/setup id in the prefix collapses to ":id" and
        // cannot act as an existence probe for that id (compliance audit F-3).
        // The former DB-side substring narrowing matched raw paths and is
        // dropped for the same reason.
        if let rawPrefix = input.pathPrefix, !rawPrefix.isEmpty {
            let prefix = Self.normalizePath(rawPrefix)
            groups = groups.filter { Self.normalizePath($0.path).hasPrefix(prefix) }
        }

        // Durations are kept as (duration → count) per route, so memory
        // grows with the distinct durations, not with the requests. A path
        // that carries an id groups to one row per request in SQL; its
        // durations still collapse here.
        var total = 0
        var statusClasses: [String: Int] = [:]
        var durationsByRoute: [String: WeightedDurations] = [:]
        var errorsByRoute: [String: Int] = [:]
        var allDurations = WeightedDurations()
        for group in groups {
            total += group.n
            statusClasses[Self.statusClass(group.statusCode), default: 0] += group.n
            let route = "\(group.method) \(Self.normalizePath(group.path))"
            durationsByRoute[route, default: WeightedDurations()].add(group.durationMs, count: group.n)
            if group.statusCode >= 400 { errorsByRoute[route, default: 0] += group.n }
            allDurations.add(group.durationMs, count: group.n)
        }

        let slowestRoutes = durationsByRoute.map { route, durations in
            RouteStat(
                route: route,
                count: durations.total,
                errorCount: errorsByRoute[route, default: 0],
                p95Ms: durations.percentile(0.95),
                maxMs: durations.max ?? 0)
        }
        .sorted { ($0.p95Ms ?? 0, $0.maxMs) > ($1.p95Ms ?? 0, $1.maxMs) }
        .prefix(limit)

        return Output(
            windowHours: windowHours,
            total: total,
            byStatusClass: statusClasses.map { StatusClassCount(statusClass: $0.key, count: $0.value) }
                .sorted { $0.statusClass < $1.statusClass },
            overall: allDurations.summary(),
            slowestRoutes: Array(slowestRoutes))
    }

    /// A multiset of durations: each value with how many requests took it.
    /// Its average and percentiles equal `durationSummary` over the expanded
    /// list, with the same nearest-lower-rank rule
    /// (`MetricBucketAccumulators.percentile`).
    struct WeightedDurations {
        private(set) var counts: [Int: Int] = [:]
        private(set) var total = 0
        private var sum = 0

        mutating func add(_ durationMs: Int, count: Int) {
            counts[durationMs, default: 0] += count
            total += count
            sum += durationMs * count
        }

        var max: Int? { counts.keys.max() }

        func percentile(_ percentile: Double) -> Int? {
            guard total > 0 else { return nil }
            let rank = min(total - 1, Swift.max(0, Int(Double(total - 1) * percentile)))
            var seen = 0
            for durationMs in counts.keys.sorted() {
                seen += counts[durationMs, default: 0]
                if seen > rank { return durationMs }
            }
            return counts.keys.max()
        }

        func summary() -> DurationSummaryResponse {
            DurationSummaryResponse(
                averageMs: total > 0 ? sum / total : nil, p50Ms: percentile(0.50), p95Ms: percentile(0.95))
        }
    }

    /// One (method, path, status, duration) group of the window, and how
    /// many requests fell in it.
    private struct RequestGroup: Decodable {
        let method: String
        let path: String
        let statusCode: Int
        let durationMs: Int
        let n: Int

        enum CodingKeys: String, CodingKey {
            case method, path, n
            case statusCode = "status_code"
            case durationMs = "duration_ms"
        }
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
