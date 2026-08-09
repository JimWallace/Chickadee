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
        /// Every assignment language the server has, and what each supports —
        /// see `MCPLanguageCapability`.
        ///
        /// Here rather than in a `get_languages` tool of its own because it is
        /// the same question this tool already answers ("what can this
        /// deployment do?"), it is static server metadata like everything else
        /// here, and an agent that must call a second tool to learn what its
        /// first tool's answer means will often skip it. Adding a field costs
        /// an agent nothing; adding a tool costs it a round-trip it has to
        /// think to make.
        let languages: [MCPLanguageCapability]
    }

    static let name = "get_server_info"
    static let description =
        "Report the deployed server's version and MCP capability surface: the Chickadee version, "
        + "the active MCP mode (read_only / read_write), the advertised content scopes, whether "
        + "writes are honored, and `languages` — every assignment language this deployment supports "
        + "with, for each, its wire token and display name, its script/generated/source file "
        + "extensions, whether it has an in-browser editor kernel or is upload-only, whether "
        + "per-student expressions can be evaluated and by which interpreter, and exactly which "
        + "pattern-family and notebook-check kinds it can render (with the reason for every "
        + "exclusion). Read `languages` BEFORE authoring for an unfamiliar language: the kinds are "
        + "NOT uniform across languages, and this is the same predicate that refuses a save, so it "
        + "will not disagree with what you are allowed to write. Also use it to confirm a deploy is "
        + "live (a tool call hits the running process, unlike a cached tool list) or to check "
        + "whether write tools will work before calling them. Read-only; touches no course, "
        + "student, or database state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "version": MCPSchema.string,
            "mcpMode": MCPSchema.string,
            "advertisedScopes": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "writeEnabled": MCPSchema.boolean,
            "languages": .object([
                "type": .string("array"),
                "description": .string(
                    "Every assignment language the server supports, and what each can render."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": MCPSchema.string,
                        "displayName": MCPSchema.string,
                        "scriptExtensions": .object([
                            "type": .string("array"), "items": MCPSchema.string,
                        ]),
                        "generatedScriptExtension": MCPSchema.string,
                        "sourceFileExtension": MCPSchema.string,
                        "submissionMode": MCPSchema.string,
                        "editorKernel": MCPSchema.string,
                        "personalizationExpressions": MCPSchema.boolean,
                        "personalizationInterpreter": MCPSchema.string,
                        "supportsNullValues": MCPSchema.boolean,
                        "supportedPatternKinds": .object([
                            "type": .string("array"), "items": MCPSchema.string,
                        ]),
                        "supportedNotebookCheckKinds": .object([
                            "type": .string("array"), "items": MCPSchema.string,
                        ]),
                        "unsupportedNotebookCheckKinds": .object([
                            "type": .string("object"),
                            "description": .string("Kind → why this language cannot render it."),
                        ]),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([
            .string("version"), .string("mcpMode"), .string("advertisedScopes"),
            .string("writeEnabled"), .string("languages"),
        ]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let mode = context.request.application.appConfig.mcp.mode
        return Output(
            version: ChickadeeVersion.current,
            mcpMode: mode.rawValue,
            advertisedScopes: mode.advertisedScopes.map(\.rawValue),
            writeEnabled: mode.scopeCeiling.contains(.write),
            languages: MCPLanguageCapability.all)
    }
}
