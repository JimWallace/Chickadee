// APIServer/MCP/Admin/AdminMCPDispatcher.swift
//
// Routes a decoded JSON-RPC message to its handler for the admin diagnostic
// surface and produces the response (or nil, for notifications).  Parallel to
// `MCPDispatcher` but trimmed: tools only (no resources), read-only (no
// fail-closed write audit).  Reuses the generic transport/JSON-RPC types
// (`JSONRPCRequest`, `MCPMethod`, `MCPInitializeResult`, pagination, the
// success-result envelope) — only the scope/context/registry layer differs.
//
// Audit of admin tool calls lands with the bearer/principal slice (the acting
// agent identity comes from the authenticated principal); this layer is pure
// dispatch.

import Core
import Foundation

struct AdminMCPDispatcher: Sendable {
    let serverInfo: MCPServerInfo
    let tools: DiagnosticToolRegistry

    init(serverInfo: MCPServerInfo, tools: DiagnosticToolRegistry = DiagnosticToolRegistry([])) {
        self.serverInfo = serverInfo
        self.tools = tools
    }

    func dispatch(_ request: JSONRPCRequest, context: AdminToolContext? = nil) async -> JSONRPCResponse? {
        guard let id = request.id else { return nil }

        guard request.jsonrpc == "2.0" else {
            return .failure(id: id, error: .invalidRequest("Unsupported \"jsonrpc\" version: \(request.jsonrpc)"))
        }
        guard let method = MCPMethod(rawValue: request.method) else {
            return .failure(id: id, error: .methodNotFound(request.method))
        }

        switch method {
        case .initialize:
            return initializeResponse(id: id, params: request.params, context: context)
        case .ping:
            return .success(id: id, result: .object([:]))
        case .initialized:
            return .success(id: id, result: .object([:]))
        case .toolsList:
            return toolsListResult(id: id, params: request.params, context: context)
        case .toolsCall:
            return await toolsCallResult(id: id, params: request.params, context: context)
        case .resourcesList, .resourcesRead:
            // The admin surface advertises tools only (no resources capability).
            return .failure(id: id, error: .methodNotFound(request.method))
        }
    }

    // MARK: - tools/list

    /// Advertises only the tools the caller can invoke: a tool is listed when
    /// the caller's granted scopes cover its `requiredScopes`.  With no context
    /// (tests), all tools are listed.
    private func toolsListResult(id: JSONRPCID, params: JSONValue?, context: AdminToolContext?) -> JSONRPCResponse {
        let visible =
            context.map { ctx in
                tools.all.filter { ctx.grantedScopes.isSuperset(of: $0.requiredScopes) }
            } ?? tools.all
        let entries = visible.map { tool -> JSONValue in
            var fields: [String: JSONValue] = [
                "name": .string(tool.name),
                "title": .string(tool.title),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ]
            if let outputSchema = tool.outputSchema {
                fields["outputSchema"] = outputSchema
            }
            if let annotations = tool.annotations, let encoded = try? JSONValue(encoding: annotations) {
                fields["annotations"] = encoded
            }
            return .object(fields)
        }
        return paginatedListResponse(id: id, key: "tools", entries: entries, params: params)
    }

    // MARK: - List pagination

    private struct ListParams: Decodable {
        let cursor: String?
    }

    private func paginatedListResponse(
        id: JSONRPCID, key: String, entries: [JSONValue], params: JSONValue?
    ) -> JSONRPCResponse {
        let cursor: String?
        do {
            cursor = try (params ?? .object([:])).decoded(as: ListParams.self).cursor
        } catch {
            return .failure(id: id, error: .invalidParams("\"cursor\" must be a string."))
        }
        guard let result = MCPListPagination.page(entries, cursor: cursor) else {
            return .failure(id: id, error: .invalidParams("Invalid cursor."))
        }
        var fields: [String: JSONValue] = [key: .array(result.page)]
        if let next = result.nextCursor {
            fields["nextCursor"] = .string(next)
        }
        return .success(id: id, result: .object(fields))
    }

    // MARK: - tools/call

    private struct ToolCallParams: Decodable {
        let name: String
        let arguments: JSONValue?
    }

    private func toolsCallResult(id: JSONRPCID, params: JSONValue?, context: AdminToolContext?) async -> JSONRPCResponse
    {
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
        // middleware's token-level gate.  The transport maps insufficient scope
        // to HTTP 403.
        guard context.grantedScopes.isSuperset(of: tool.requiredScopes) else {
            let required = tool.requiredScopes.map(\.rawValue).sorted().joined(separator: " ")
            return .failure(id: id, error: .insufficientScope(required))
        }

        let response: JSONRPCResponse
        let outcome: String
        do {
            let output = try await tool.invoke(call.arguments ?? .object([:]), context)
            outcome = MCPToolOutcome.success.rawValue
            response = .success(id: id, result: mcpToolSuccessResult(output))
        } catch let error as MCPToolError {
            outcome = MCPToolOutcome(error).rawValue
            response = .success(id: id, result: errorToolResult(error))
        } catch {
            outcome = MCPToolOutcome.failed.rawValue
            response = .failure(id: id, error: .internalError("Tool \(call.name) failed."))
        }
        // Best-effort audit (read-only surface, so no fail-closed): one row per
        // executed call, attributed to the subject (suffixed -MCP) so agent reads
        // are distinguishable from a human's web actions. Never logs arguments.
        await auditToolCall(name: call.name, context: context, outcome: outcome)
        return response
    }

    private func auditToolCall(name: String, context: AdminToolContext, outcome: String) async {
        var metadata = ["tool": name, "outcome": outcome]
        if let agent = context.actingClientName {
            metadata["via_agent"] = agent
        }
        await AuditLogger.record(
            action: .adminMcpToolCalled,
            metadata: metadata,
            actorUsernameOverride: "\(context.subject)-MCP",
            on: context.request)
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

    private func initializeResponse(
        id: JSONRPCID, params: JSONValue?, context: AdminToolContext?
    ) -> JSONRPCResponse {
        let client = try? (params ?? .object([:])).decoded(as: MCPInitializeParams.self)
        let negotiated =
            client?.protocolVersion.flatMap { requested in
                MCPProtocol.supportedVersions.contains(requested) ? requested : nil
            } ?? MCPProtocol.version
        if let context {
            let name = client?.clientInfo?.name ?? "unknown"
            let clientVersion = client?.clientInfo?.version ?? "unknown"
            let requested = client?.protocolVersion ?? "none"
            context.logger.info(
                "Admin MCP initialize: client=\(name)/\(clientVersion) requestedProtocolVersion=\(requested) negotiated=\(negotiated)"
            )
        }
        let result = MCPInitializeResult(
            protocolVersion: negotiated,
            capabilities: .toolsOnly,
            serverInfo: serverInfo,
            instructions: AdminMCPServerInstructions.text
        )
        do {
            return .success(id: id, result: try JSONValue(encoding: result))
        } catch {
            return .failure(id: id, error: .internalError("Failed to encode initialize result."))
        }
    }
}
