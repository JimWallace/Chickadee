// APIServer/MCP/Transport/MCPDispatcher.swift
//
// Routes a decoded JSON-RPC message to its MCP handler and produces the
// response (or nil, for notifications).  Transport-agnostic: the HTTP route
// (MCPRoutes) owns framing, Host/Origin checks, status codes, and building the
// ToolContext; the dispatcher owns method semantics and tool dispatch.
// https://modelcontextprotocol.io/specification/2025-11-25

import Core

/// Maps a JSON-RPC request to an MCP response.  Returns nil for notifications,
/// which receive no response per the spec.
struct MCPDispatcher: Sendable {
    let serverInfo: MCPServerInfo
    let tools: ToolRegistry

    init(serverInfo: MCPServerInfo, tools: ToolRegistry = ToolRegistry([])) {
        self.serverInfo = serverInfo
        self.tools = tools
    }

    func dispatch(_ request: JSONRPCRequest, context: ToolContext? = nil) async -> JSONRPCResponse? {
        // Notifications (no id) never receive a response, whatever they carry.
        guard let id = request.id else { return nil }

        guard request.jsonrpc == "2.0" else {
            return .failure(id: id, error: .invalidRequest("Unsupported \"jsonrpc\" version: \(request.jsonrpc)"))
        }
        guard let method = MCPMethod(rawValue: request.method) else {
            return .failure(id: id, error: .methodNotFound(request.method))
        }

        switch method {
        case .initialize:
            return initializeResponse(id: id)
        case .ping:
            return .success(id: id, result: .object([:]))
        case .initialized:
            // Normally a notification (handled above).  If a client sends it
            // with an id, ack with an empty result rather than erroring.
            return .success(id: id, result: .object([:]))
        case .toolsList:
            return .success(id: id, result: toolsListResult())
        case .toolsCall:
            return await toolsCallResult(id: id, params: request.params, context: context)
        case .resourcesList:
            return .success(id: id, result: .object(["resources": .array([])]))
        case .resourcesRead:
            // TODO(PR B): expose authoring content (e.g. suite manifests) as resources.
            // https://modelcontextprotocol.io/specification/2025-11-25/server/resources
            return .failure(id: id, error: .invalidParams("No resources are registered yet."))
        }
    }

    // MARK: - tools/list

    private func toolsListResult() -> JSONValue {
        let entries = tools.all.map { tool in
            JSONValue.object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ])
        }
        return .object(["tools": .array(entries)])
    }

    // MARK: - tools/call

    private struct ToolCallParams: Decodable {
        let name: String
        let arguments: JSONValue?
    }

    private func toolsCallResult(id: JSONRPCID, params: JSONValue?, context: ToolContext?) async -> JSONRPCResponse {
        guard let context else {
            return .failure(id: id, error: .internalError("Tool execution context is unavailable."))
        }
        let call: ToolCallParams
        do {
            call = try (params ?? .object([:])).decoded(as: ToolCallParams.self)
        } catch {
            return .failure(id: id, error: .invalidParams("tools/call requires a \"name\" and optional \"arguments\"."))
        }
        guard let tool = tools.tool(named: call.name) else {
            return .failure(id: id, error: .invalidParams("Unknown tool: \(call.name)"))
        }
        // Per-tool scope enforcement, defence in depth on top of the bearer
        // middleware's token-level scope gate: the caller's granted scopes must
        // cover everything this tool declares.  The transport maps an
        // insufficient-scope failure to HTTP 403.
        guard context.grantedScopes.isSuperset(of: tool.requiredScopes) else {
            let required = tool.requiredScopes.map(\.rawValue).sorted().joined(separator: " ")
            return .failure(id: id, error: .insufficientScope(required))
        }
        // Audit every authorized tool call as the human subject, attributed to
        // the acting agent (when the token carries one).
        await auditToolCall(name: call.name, context: context)
        do {
            let output = try await tool.invoke(call.arguments ?? .object([:]), context)
            return .success(id: id, result: successToolResult(output))
        } catch let error as MCPToolError {
            // Tool-originated failures are reported inside the result with
            // isError:true so the model can see and correct them.
            return .success(id: id, result: errorToolResult(error))
        } catch {
            return .failure(id: id, error: .internalError("Tool \(call.name) failed."))
        }
    }

    /// Records an `mcp.tool_called` audit entry. The actor is the token subject
    /// suffixed with `-MCP` (e.g. `jsmith-MCP`) so agent-made changes are
    /// tracked separately from the human's own web actions in the admin audit
    /// log; the acting agent is in `via_agent` when present. Never logs tool
    /// arguments.
    private func auditToolCall(name: String, context: ToolContext) async {
        var metadata = ["tool": name]
        if let agent = context.actingClientName {
            metadata["via_agent"] = agent
        }
        await AuditLogger.record(
            action: .mcpToolCalled,
            metadata: metadata,
            actorUsernameOverride: "\(context.subject)-MCP",
            on: context.request)
    }

    private func successToolResult(_ structured: JSONValue) -> JSONValue {
        let text = (try? structured.encodedString()) ?? ""
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": structured,
            "isError": .bool(false),
        ])
    }

    private func errorToolResult(_ error: MCPToolError) -> JSONValue {
        let message: String
        switch error {
        case .unknownTool(let name):
            message = "Unknown tool: \(name)"
        case .invalidArguments(let tool, let detail):
            message = "Invalid arguments for \(tool): \(detail)"
        case .notAuthorized(let tool, let detail):
            message = "Not authorized for \(tool): \(detail)"
        case .executionFailed(let tool, let detail):
            message = "\(tool) failed: \(detail)"
        }
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    private func initializeResponse(id: JSONRPCID) -> JSONRPCResponse {
        let result = MCPInitializeResult(
            protocolVersion: MCPProtocol.version,
            capabilities: .v1,
            serverInfo: serverInfo
        )
        do {
            return .success(id: id, result: try JSONValue(encoding: result))
        } catch {
            return .failure(id: id, error: .internalError("Failed to encode initialize result."))
        }
    }
}
