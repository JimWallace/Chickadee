// APIServer/MCP/Admin/Tools/GetDeploymentInfoTool.swift
//
// Read tool: report the deployed server's version and diagnostic-surface
// capability. The admin analog of the content surface's get_server_info, and the
// first tool that proves the admin dispatch pipeline end to end.
//
// Deliberately DB-free: returns only static server metadata, so it stays a
// useful liveness check even when the database is unavailable (which is itself a
// thing an operator wants to diagnose).  No student, course, or DB state.

import Core
import Vapor

struct GetDeploymentInfoTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        /// The deployed Chickadee version (`ChickadeeVersion.current`).
        let version: String
        /// The Vapor environment name (e.g. "production", "development").
        let environment: String
        /// The active admin-MCP mode ("read_only"; the endpoint is unmounted in
        /// "off", so a reachable call is never that).
        let adminMcpMode: String
        /// Scopes the admin surface advertises and honors, in stable order.
        let advertisedScopes: [String]
        /// The content-authoring MCP mode ("off" / "read_only" / "read_write"),
        /// a capability probe of the other surface.
        let contentMcpMode: String
    }

    static let name = "get_deployment_info"
    static let description =
        "Report the deployed server's version and capability surface: the Chickadee version, the "
        + "Vapor environment, the admin diagnostic MCP mode and its advertised scopes, and the "
        + "content-authoring MCP mode. Use it to confirm a deploy is live (a tool call hits the "
        + "running process, unlike a cached tool list). Read-only; touches no course, student, or "
        + "database state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "version": .object(["type": .string("string")]),
            "environment": .object(["type": .string("string")]),
            "adminMcpMode": .object(["type": .string("string")]),
            "advertisedScopes": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "contentMcpMode": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("version"), .string("environment"), .string("adminMcpMode"),
            .string("advertisedScopes"), .string("contentMcpMode"),
        ]),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        let config = context.request.application.appConfig
        return Output(
            version: ChickadeeVersion.current,
            environment: context.request.application.environment.name,
            adminMcpMode: config.adminMCP.mode.rawValue,
            advertisedScopes: config.adminMCP.mode.advertisedScopes.map(\.rawValue),
            contentMcpMode: config.mcp.mode.rawValue)
    }
}
