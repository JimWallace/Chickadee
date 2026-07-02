// APIServer/MCP/Transport/MCPDispatcher.swift
//
// Routes a decoded JSON-RPC message to its MCP handler and produces the
// response (or nil, for notifications).  Transport-agnostic: the HTTP route
// (MCPRoutes) owns framing, Host/Origin checks, status codes, and building the
// ToolContext; the dispatcher owns method semantics and tool dispatch.
// https://modelcontextprotocol.io/specification/2025-11-25

import Core
import Foundation

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
            return initializeResponse(id: id, params: request.params, context: context)
        case .ping:
            return .success(id: id, result: .object([:]))
        case .initialized:
            // Normally a notification (handled above).  If a client sends it
            // with an id, ack with an empty result rather than erroring.
            return .success(id: id, result: .object([:]))
        case .toolsList:
            return toolsListResult(id: id, params: request.params, context: context)
        case .toolsCall:
            return await toolsCallResult(id: id, params: request.params, context: context)
        case .resourcesList:
            return await resourcesListResult(id: id, params: request.params, context: context)
        case .resourcesRead:
            return await resourcesReadResult(id: id, params: request.params, context: context)
        }
    }

    // MARK: - resources/list, resources/read

    private let resources = MCPResourceProvider()

    private func resourcesListResult(
        id: JSONRPCID, params: JSONValue?, context: ToolContext?
    ) async -> JSONRPCResponse {
        guard let context else {
            return .failure(id: id, error: .internalError("Resource execution context is unavailable."))
        }
        guard context.grantedScopes.contains(.read) else {
            return .failure(id: id, error: .insufficientScope(ContentScope.read.rawValue))
        }
        do {
            let full = try await resources.list(context: context)
            guard case .object(let fields) = full, case .array(let entries)? = fields["resources"] else {
                return .failure(id: id, error: .internalError("Failed to list resources."))
            }
            return mcpPaginatedListResponse(id: id, key: "resources", entries: entries, params: params)
        } catch {
            return .failure(id: id, error: .internalError("Failed to list resources."))
        }
    }

    private struct ResourceReadParams: Decodable {
        let uri: String
    }

    private func resourcesReadResult(
        id: JSONRPCID, params: JSONValue?, context: ToolContext?
    ) async -> JSONRPCResponse {
        guard let context else {
            return .failure(id: id, error: .internalError("Resource execution context is unavailable."))
        }
        guard context.grantedScopes.contains(.read) else {
            return .failure(id: id, error: .insufficientScope(ContentScope.read.rawValue))
        }
        let read: ResourceReadParams
        do {
            read = try (params ?? .object([:])).decoded(as: ResourceReadParams.self)
        } catch {
            return .failure(id: id, error: .invalidParams("resources/read requires a \"uri\"."))
        }
        do {
            return .success(id: id, result: try await resources.read(uri: read.uri, context: context))
        } catch let error as MCPToolError {
            // Unknown/inaccessible resource → invalidParams; a genuine lookup
            // failure → internalError. Mirrors the tool path's error mapping.
            if case .executionFailed(_, let detail) = error {
                return .failure(id: id, error: .internalError(detail))
            }
            let detail: String
            switch error {
            case .invalidArguments(_, let message), .notAuthorized(_, let message):
                detail = message
            default:
                detail = "Unknown resource."
            }
            return .failure(id: id, error: .invalidParams(detail))
        } catch {
            return .failure(id: id, error: .internalError("Failed to read resource."))
        }
    }

    // MARK: - tools/list

    /// Advertises only the tools the caller can actually invoke: a tool is
    /// listed when the caller's granted scopes cover its `requiredScopes`.  In
    /// read_only mode the bearer middleware has already clamped granted scopes
    /// to {read}, so write tools drop out of the listing here rather than being
    /// advertised only to fail with 403 on call.  When no context is available
    /// (non-transport callers / tests), all tools are listed.
    private func toolsListResult(id: JSONRPCID, params: JSONValue?, context: ToolContext?) -> JSONRPCResponse {
        let visible =
            context.map { ctx in
                tools.all.filter { ctx.grantedScopes.isSuperset(of: $0.requiredScopes) }
            } ?? tools.all
        return mcpPaginatedListResponse(
            id: id, key: "tools", entries: mcpToolsListEntries(visible), params: params)
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
        // Resolve the target resource from the arguments up front so a failing
        // call is still attributed to what it acted on. Only the identifier is
        // captured here — never the argument values.
        let target = MCPAuditTarget(arguments: call.arguments)

        // Fail closed for writes: a state-changing tool must not run unless its
        // audit record is durably persisted first. Read tools stay best-effort
        // (a read that can't be audited still degrades to a logged marker, but
        // is not blocked).
        var writeAuditRow: APIAuditLogEntry?
        if tool.requiredScopes.contains(.write) {
            writeAuditRow = await recordToolCall(name: call.name, context: context, target: target)
            guard writeAuditRow != nil else {
                return .failure(
                    id: id,
                    error: .internalError(
                        "Refusing to run \(call.name): its audit record could not be persisted."))
            }
        }

        let response: JSONRPCResponse
        let outcome: MCPToolOutcome
        do {
            let output = try await tool.invoke(call.arguments ?? .object([:]), context)
            outcome = .success
            response = .success(id: id, result: mcpToolSuccessResult(output))
        } catch let error as MCPToolError {
            // Tool-originated failures are reported inside the result with
            // isError:true so the model can see and correct them.
            outcome = MCPToolOutcome(error)
            response = .success(id: id, result: mcpToolErrorResult(error))
        } catch {
            outcome = .failed
            response = .failure(id: id, error: .internalError("Tool \(call.name) failed."))
        }

        if let writeAuditRow {
            // Stamp the outcome onto the row already persisted before the write.
            await AuditLogger.updateMetadata(
                writeAuditRow, merging: ["outcome": outcome.rawValue], on: context.request)
        } else {
            // Read tool: one best-effort row carrying the outcome.
            _ = await recordToolCall(
                name: call.name, context: context, target: target, outcome: outcome)
        }
        return response
    }

    /// Records an `mcp.tool_called` audit entry and returns the persisted row
    /// (nil if the write failed). The actor is the token subject suffixed with
    /// `-MCP` (e.g. `jsmith-MCP`) so agent-made changes are tracked separately
    /// from the human's own web actions in the admin audit log; the acting agent
    /// is in `via_agent` when present. The target resource (assignment public ID
    /// or course code) and, when known, the outcome are recorded. Never logs
    /// tool arguments.
    @discardableResult
    func recordToolCall(
        name: String, context: ToolContext,
        target: MCPAuditTarget? = nil, outcome: MCPToolOutcome? = nil
    ) async -> APIAuditLogEntry? {
        var metadata = ["tool": name]
        if let agent = context.actingClientName {
            metadata["via_agent"] = agent
        }
        if let outcome {
            metadata["outcome"] = outcome.rawValue
        }
        return await AuditLogger.recordReturning(
            action: .mcpToolCalled,
            targetType: target?.type,
            targetID: target?.id,
            metadata: metadata,
            actorUsernameOverride: "\(context.subject)-MCP",
            on: context.request)
    }

    /// Best-effort audit used by the streaming `validate_assignment` path (a read
    /// tool, so no fail-closed): records the call without propagating failure.
    func auditToolCall(
        name: String, context: ToolContext,
        target: MCPAuditTarget? = nil, outcome: MCPToolOutcome? = nil
    ) async {
        _ = await recordToolCall(name: name, context: context, target: target, outcome: outcome)
    }

    private func initializeResponse(
        id: JSONRPCID, params: JSONValue?, context: ToolContext?
    ) -> JSONRPCResponse {
        mcpInitializeResponse(
            id: id, params: params,
            capabilities: .v1,
            serverInfo: serverInfo,
            instructions: MCPServerInstructions.text,
            logger: context?.logger,
            logLabel: "MCP")
    }
}

/// Classification of a tool call's outcome, recorded in the audit metadata so a
/// reviewer can see whether a call succeeded or failed without the tool ever
/// logging its arguments.
enum MCPToolOutcome: String, Sendable {
    case success
    case invalidArguments = "invalid_arguments"
    case notAuthorized = "not_authorized"
    case executionFailed = "execution_failed"
    case failed

    init(_ error: MCPToolError) {
        switch error {
        case .unknownTool: self = .failed
        case .invalidArguments: self = .invalidArguments
        case .notAuthorized: self = .notAuthorized
        case .executionFailed: self = .executionFailed
        }
    }
}

/// The resource a tool acted on, extracted from the call arguments for the audit
/// record. Records only the resource identifier and its kind (assignment public
/// ID or course code) — never the argument values (script bodies, notebook
/// content, solution text), which must never land in the audit log.
struct MCPAuditTarget {
    let type: AuditTargetType
    let id: String

    init(type: AuditTargetType, id: String) {
        self.type = type
        self.id = id
    }

    init?(arguments: JSONValue?) {
        guard case .object(let fields)? = arguments else { return nil }
        if case .string(let publicID)? = fields["assignmentPublicID"], !publicID.isEmpty {
            type = .assignment
            id = publicID
        } else if case .string(let courseCode)? = fields["courseCode"], !courseCode.isEmpty {
            type = .course
            id = courseCode
        } else {
            return nil
        }
    }
}
