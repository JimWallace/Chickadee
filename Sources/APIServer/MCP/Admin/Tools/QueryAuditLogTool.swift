// APIServer/MCP/Admin/Tools/QueryAuditLogTool.swift
//
// Read tool: audit-log activity as AGGREGATE COUNTS over a window — totals by
// action and by category.  Useful for spotting a failed-login spike, a burst of
// MCP refresh-reuse-detected events, or a wave of role changes, without
// exposing who did what.
//
// PII boundary (the reason this is counts-only): audit_log rows carry an actor
// (actor_user_id / actor_username — which CAN be a student on login/registration
// events), a remote IP, and free-form metadata that may embed user ids. The
// design record (docs/admin-mcp.md §4.2) excluded the table from v1 for exactly
// this. This tool therefore returns ONLY per-action / per-category counts —
// never a row, actor, IP, or metadata blob — so the no-student-data guarantee
// holds by construction.

import Core
import Fluent
import Vapor

struct QueryAuditLogTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Look-back window in hours (default 168 = 7 days; clamped 1…2160).
        var windowHours: Int?
        /// Optional exact action filter (e.g. "auth.login_failure").
        var action: String?
    }

    struct CountEntry: Encodable, Sendable {
        let key: String
        let label: String
        let count: Int
    }

    struct Output: Encodable, Sendable {
        let windowHours: Int
        let total: Int
        let byAction: [CountEntry]
        let byCategory: [CountEntry]
    }

    static let name = "query_audit_log"
    static let description =
        "Audit-log activity as aggregate counts over a window: totals by action (e.g. "
        + "auth.login_failure, mcp.refresh_reuse_detected, user.role_changed) and by category "
        + "(Authentication, MCP / agents, Users & roles, …). Use it to spot a failed-login spike, a "
        + "burst of refresh-token-reuse events, or a wave of admin actions. Optional windowHours "
        + "(default 168, max 2160) and an exact action filter. Read-only and COUNTS ONLY — by design "
        + "it never returns an audit row, actor, IP, or metadata (actors can be students), so no "
        + "student identifier is reachable."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "windowHours": .object([
                "type": .string("integer"),
                "description": .string("Look-back window in hours (default 168, max 2160)."),
            ]),
            "action": .object([
                "type": .string("string"),
                "description": .string("Optional exact action filter, e.g. \"auth.login_failure\"."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let windowHours = min(max(input.windowHours ?? 168, 1), 2160)
        let since = Date().addingTimeInterval(Double(-windowHours) * 3600)

        var query = APIAuditLogEntry.query(on: context.db)
            .filter(\.$createdAt >= since)
        if let action = input.action, !action.isEmpty {
            query = query.filter(\.$action == action)
        }
        // Project to the action column only — no actor, IP, or metadata is ever
        // loaded into this tool, let alone returned.
        let actions = try await query.all(\.$action)

        var byActionRaw: [String: Int] = [:]
        var byCategoryRaw: [String: Int] = [:]
        for raw in actions {
            byActionRaw[raw, default: 0] += 1
            let display = AuditActionDisplay.categoryLabel(forRaw: raw)
            byCategoryRaw[display.category, default: 0] += 1
        }

        let byAction = byActionRaw.map { raw, count in
            CountEntry(key: raw, label: AuditActionDisplay.categoryLabel(forRaw: raw).label, count: count)
        }
        .sorted { ($0.count, $1.key) > ($1.count, $0.key) }

        let byCategory = byCategoryRaw.map { category, count in
            CountEntry(key: category, label: category, count: count)
        }
        .sorted { ($0.count, $1.key) > ($1.count, $0.key) }

        return Output(
            windowHours: windowHours, total: actions.count, byAction: byAction, byCategory: byCategory)
    }
}
