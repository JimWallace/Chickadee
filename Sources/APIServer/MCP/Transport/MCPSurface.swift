// APIServer/MCP/Transport/MCPSurface.swift
//
// One MCP surface — the content surface or the admin diagnostic surface — as
// the shared tools/list and tools/call code sees it (#2339). A surface names
// its scope, context and per-tool trait types, and supplies the steps around a
// call that really differ between the two: the content surface persists a
// write's audit row before the tool runs (fail closed) and snapshots what the
// write changed; the admin surface re-checks the admin role. Everything else —
// decoding the call, the scope guard, the result envelopes, the error mapping
// and its logging — is one implementation, so the two surfaces cannot drift.
//
// The scope types stay distinct (`ContentScope`, `DiagnosticScope`), so a
// content token can never satisfy an admin tool's check, and a tool of one
// surface cannot be registered on the other.

import Core
import Logging

/// The context a surface hands its tools: what the shared call code reads.
protocol MCPCallContext {
    associatedtype Scope: Hashable & Sendable
    var grantedScopes: Set<Scope> { get }
    var logger: Logger { get }
}

/// One MCP surface, as the shared tools/list and tools/call code sees it.
protocol MCPSurface: Sendable {
    associatedtype Scope: RawRepresentable & Hashable & Sendable where Scope.RawValue == String
    associatedtype Context: MCPCallContext where Context.Scope == Scope
    /// The per-tool facts the hooks read (empty on the content surface).
    associatedtype ToolTraits: Sendable
    /// What `admit` hands on to `finish` (the content surface's audit row).
    associatedtype Admission

    /// The prefix of this surface's log lines ("MCP", "Admin MCP").
    static var logLabel: String { get }

    /// Runs before the tool, outside the tool's error handling. A failure
    /// refuses the call with a JSON-RPC error, and the tool does not run.
    static func admit(
        _ tool: AnyMCPTool<Self>, call: MCPToolCall, context: Context
    ) async -> Result<Admission, JSONRPCError>

    /// Runs just before the tool, inside its error handling: an
    /// `MCPToolError` thrown here reaches the agent as a tool error.
    static func beforeInvoke(_ tool: AnyMCPTool<Self>, context: Context) async throws

    /// Runs after the tool succeeded.
    static func afterSuccess(call: MCPToolCall, context: Context) async

    /// Records the call's outcome.
    static func finish(
        call: MCPToolCall, admission: Admission, outcome: MCPToolOutcome, context: Context
    ) async
}

/// The per-tool traits of a surface whose hooks read none.
struct MCPNoToolTraits: Sendable {}

/// The `params` of a `tools/call` request.
struct MCPToolCall: Decodable, Sendable {
    let name: String
    let arguments: JSONValue?
}

// MARK: - tools/list

/// Advertises only the tools the caller can actually invoke: a tool is listed
/// when the caller's granted scopes cover its `requiredScopes`. On the content
/// surface in read_only mode the bearer middleware has already clamped granted
/// scopes to {read}, so write tools drop out here rather than being advertised
/// only to fail with 403 on call. With no context (non-transport callers,
/// tests), all tools are listed.
func mcpToolsListResponse<Surface>(
    id: JSONRPCID, params: JSONValue?,
    tools: MCPToolRegistry<AnyMCPTool<Surface>>, context: Surface.Context?
) -> JSONRPCResponse {
    let visible =
        context.map { context in
            tools.all.filter { context.grantedScopes.isSuperset(of: $0.requiredScopes) }
        } ?? tools.all
    return mcpPaginatedListResponse(
        id: id, key: "tools", entries: mcpToolsListEntries(visible), params: params)
}

// MARK: - tools/call

/// Runs one `tools/call` on a surface: decode the call, find the tool, guard
/// its scopes, then the surface's hooks around the tool itself.
func mcpToolsCallResponse<Surface>(
    id: JSONRPCID, params: JSONValue?,
    tools: MCPToolRegistry<AnyMCPTool<Surface>>, context: Surface.Context?
) async -> JSONRPCResponse {
    guard let context else {
        return .failure(id: id, error: .internalError("Tool execution context is unavailable."))
    }
    let call: MCPToolCall
    do {
        call = try (params ?? .object([:])).decoded(as: MCPToolCall.self)
    } catch {
        return .failure(id: id, error: .invalidParams("tools/call requires a \"name\" and optional \"arguments\"."))
    }
    guard let tool = tools.tool(named: call.name) else {
        return .failure(id: id, error: .invalidParams("Unknown tool: \(call.name)"))
    }
    // Per-tool scope enforcement, defence in depth on top of the bearer
    // middleware's token-level scope gate: the caller's granted scopes must
    // cover everything this tool declares. The transport maps an
    // insufficient-scope failure to HTTP 403.
    guard context.grantedScopes.isSuperset(of: tool.requiredScopes) else {
        let required = tool.requiredScopes.map(\.rawValue).sorted().joined(separator: " ")
        return .failure(id: id, error: .insufficientScope(required))
    }

    let admission: Surface.Admission
    switch await Surface.admit(tool, call: call, context: context) {
    case .success(let admitted):
        admission = admitted
    case .failure(let error):
        return .failure(id: id, error: error)
    }

    let response: JSONRPCResponse
    let outcome: MCPToolOutcome
    do {
        try await Surface.beforeInvoke(tool, context: context)
        let output = try await tool.invoke(call.arguments ?? .object([:]), context)
        await Surface.afterSuccess(call: call, context: context)
        outcome = .success
        response = .success(id: id, result: mcpToolSuccessResult(output))
    } catch let error as MCPToolError {
        // Tool-originated failures are reported inside the result with
        // isError:true so the model can see and correct them.
        outcome = MCPToolOutcome(error)
        response = .success(id: id, result: mcpToolErrorResult(error, tool: call.name))
    } catch {
        // Any other throw is opaque to the agent (bare -32603), so the
        // underlying error must at least reach the log ring buffer — this is
        // how a Postgres permission-denied on the least-privilege MCP role
        // surfaces (e.g. the missing result_collections grant).
        context.logger.error("\(Surface.logLabel) tool \(call.name) failed: \(error)")
        outcome = .failed
        response = .failure(id: id, error: .internalError("Tool \(call.name) failed."))
    }
    await Surface.finish(call: call, admission: admission, outcome: outcome, context: context)
    return response
}

// MARK: - Routing

/// What the checks every surface runs before it routes a request decided.
enum MCPRouting {
    /// A notification (no id): it receives no response, whatever it carries.
    case notification
    /// The request is malformed or names no method this server knows.
    case refused(JSONRPCResponse)
    /// A known method, to be handled by the surface.
    case method(MCPMethod, id: JSONRPCID)

    init(_ request: JSONRPCRequest) {
        guard let id = request.id else {
            self = .notification
            return
        }
        guard request.jsonrpc == "2.0" else {
            self = .refused(
                .failure(id: id, error: .invalidRequest("Unsupported \"jsonrpc\" version: \(request.jsonrpc)")))
            return
        }
        guard let method = MCPMethod(rawValue: request.method) else {
            self = .refused(.failure(id: id, error: .methodNotFound(request.method)))
            return
        }
        self = .method(method, id: id)
    }
}
