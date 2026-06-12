// APIServer/MCP/Tools/GetServerInfoTool.swift
//
// Read tool: report the deployed server's version and MCP capability surface.
// content:read.
//
// Why a tool when `initialize` already carries `serverInfo.version`: a tool
// *call* is a live round-trip to the running process, whereas a client may
// cache the `initialize` result and the `tools/list` catalog for the lifetime
// of its connection.  When an operator ships a new build, an agent holding a
// cached catalog can't tell "the server isn't updated yet" from "my catalog is
// stale" — calling this tool answers it unambiguously, since the response comes
// straight from the live process.  It doubles as a capability probe (mode +
// advertised scopes) so an agent can decide whether writes are honored without
// a trial write that 403s.
//
// Deliberately DB-free: it returns only static server metadata, so it stays a
// useful liveness check even if the database is unavailable.

import Core

struct GetServerInfoTool: ContentTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        /// The deployed Chickadee version (`ChickadeeVersion.current`).
        let version: String
        /// The active MCP mode: "read_only" or "read_write" (the endpoint is
        /// unmounted in "off", so a reachable call is never that).
        let mcpMode: String
        /// Scopes this mode advertises and honors, in stable order.
        let advertisedScopes: [String]
        /// Convenience flag: true when `content:write` is honored (read_write).
        let writeEnabled: Bool
    }

    static let name = "get_server_info"
    static let description =
        "Report the deployed server's version and MCP capability surface: the Chickadee version, "
        + "the active MCP mode (read_only / read_write), the advertised content scopes, and whether "
        + "writes are honored. Use it to confirm a deploy is live (a tool call hits the running "
        + "process, unlike a cached tool list) or to check whether write tools will work before "
        + "calling them. Read-only; touches no course, student, or database state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "version": .object(["type": .string("string")]),
            "mcpMode": .object(["type": .string("string")]),
            "advertisedScopes": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "writeEnabled": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("version"), .string("mcpMode"), .string("advertisedScopes"), .string("writeEnabled"),
        ]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let mode = context.request.application.appConfig.mcp.mode
        return Output(
            version: ChickadeeVersion.current,
            mcpMode: mode.rawValue,
            advertisedScopes: mode.advertisedScopes.map(\.rawValue),
            writeEnabled: mode.scopeCeiling.contains(.write))
    }
}
