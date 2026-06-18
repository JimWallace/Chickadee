// APIServer/MCP/Admin/Tools/GetActiveUsersSeriesTool.swift
//
// Read tool: the time-series data behind the admin dashboard's "Active Users"
// chart — distinct active users per time bucket over a trailing window.  Wraps
// the same builder the dashboard polls (`GET /admin/activity`,
// `ActivityChartService.chartData`).  Returns per-bucket DISTINCT COUNTS only —
// never a user identifier.

import Core
import Vapor

struct GetActiveUsersSeriesTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Window token: "24h" (24 hourly buckets), "1w" (7 daily buckets), or
        /// "1m" (30 daily buckets). Defaults to "24h".
        var window: String?
    }

    /// The existing dashboard chart payload, reused verbatim — distinct-user
    /// counts per bucket only, no identifiers.
    typealias Output = ActivityChartData

    static let name = "get_active_users_series"
    static let description =
        "Time-series data behind the admin dashboard's \"Active Users\" chart: distinct active users "
        + "per time bucket over a trailing window. Optional window: \"24h\" (24 hourly buckets, the "
        + "default), \"1w\" (7 daily buckets), or \"1m\" (30 daily buckets). Each bucket carries a "
        + "label, an ISO-8601 start, and the distinct-user count. Read-only; per-bucket distinct "
        + "counts only — no user identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "window": .object([
                "type": .string("string"),
                "enum": .array([.string("24h"), .string("1w"), .string("1m")]),
                "description": .string("Trailing window: 24h (default), 1w, or 1m."),
            ])
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let window: ActivityWindow
        if let raw = input.window, !raw.isEmpty {
            guard let parsed = ActivityWindow(rawValue: raw) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "Unknown window '\(raw)'. Use 24h, 1w, or 1m.")
            }
            window = parsed
        } else {
            window = .day
        }

        return try await ActivityChartService.chartData(window: window, on: context.db)
    }
}
