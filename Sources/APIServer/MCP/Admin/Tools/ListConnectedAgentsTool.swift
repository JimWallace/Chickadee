// APIServer/MCP/Admin/Tools/ListConnectedAgentsTool.swift
//
// Read tool: the MCP OAuth grants ("connected agents") — which agents hold a
// browser-flow authorization, their scopes, owner, and last-used/expiry/revoked
// state.  Wraps the same builder the admin /admin/mcp panel uses
// (`MCPAgentsRoutes.grantRows`, admin/all-grants view).  Use it to diagnose why
// a connector can't read/write (scope or expiry) or to audit what's connected.
//
// PII note: a grant's owner is the human who authorized it. The content MCP
// consent gate requires `isInstructor` and the admin diagnostic gate requires
// `isAdmin`, so grant owners are instructors/admins — never students. No grade,
// submission, or enrollment data is exposed; the refresh-token hash is never
// included (grantRows omits it).

import Core
import Fluent
import Vapor

struct ListConnectedAgentsTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Include revoked grants (default true — they carry a `revoked` flag).
        var includeRevoked: Bool?
    }

    struct Output: Encodable, Sendable {
        let generatedAt: Date
        let total: Int
        let agents: [AgentGrantRow]
    }

    static let name = "list_connected_agents"
    static let description =
        "MCP OAuth grants (\"connected agents\"): each agent holding a browser-flow authorization, "
        + "with its name, scopes, owner (the instructor/admin who authorized it — never a student), "
        + "and authorized / last-used / expires timestamps and revoked flag. Optional includeRevoked "
        + "(default true). Use it to diagnose why a connector can't read/write (scope or expiry) or to "
        + "audit what's connected. Read-only; no refresh-token secrets, grades, submissions, or "
        + "enrollment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "includeRevoked": .object([
                "type": .string("boolean"),
                "description": .string("Include revoked grants (default true)."),
            ])
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        var query = MCPGrant.query(on: context.db).sort(\.$createdAt, .descending)
        if input.includeRevoked == false {
            query = query.filter(\.$revoked == false)
        }
        let grants = try await query.all()
        let rows = try await MCPAgentsRoutes.grantRows(grants, includeOwner: true, on: context.db)
        return Output(generatedAt: Date(), total: rows.count, agents: rows)
    }
}
