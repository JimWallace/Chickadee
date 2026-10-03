// APIServer/MCP/Admin/Tools/GetActiveUsersSeriesTool.swift
//
// Read tool: the time-series data behind the admin dashboard's "Active Users"
// chart — distinct active users per time bucket over a trailing window.  Wraps
// the same builder the dashboard polls (`GET /admin/activity`,
// `UserActivityChartService.chartData`).  Returns per-bucket DISTINCT COUNTS only —
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
                "enum": MCPEnumProse<ActivityWindow>.jsonEnum,
                "description": .string(
                    "Trailing window: \(MCPEnumProse<ActivityWindow>.orList). Default \(ActivityWindow.day.rawValue)."),
            ])
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let window: ActivityWindow
        if let raw = input.window, !raw.isEmpty {
            window = try MCPEnumProse<ActivityWindow>.parse(raw, tool: Self.name, field: "window")
        } else {
            window = .day
        }

        return try await UserActivityChartService.chartData(window: window, on: context.db)
    }
}
