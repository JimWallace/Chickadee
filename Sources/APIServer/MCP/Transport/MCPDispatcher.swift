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

    /// Routes one message and, for a modern-era request, stamps the modern
    /// result envelope (`resultType` + server `_meta`) on the way out. `era`
    /// defaults to legacy so non-transport callers keep the historical shape.
    func dispatch(
        _ request: JSONRPCRequest, context: ToolContext? = nil, era: MCPEra = .legacy
    ) async -> JSONRPCResponse? {
        guard let response = await route(request, context: context) else { return nil }
        return mcpModernized(response, era: era, serverInfo: serverInfo)
    }

    private func route(_ request: JSONRPCRequest, context: ToolContext?) async -> JSONRPCResponse? {
        let method: MCPMethod
        let id: JSONRPCID
        switch MCPRouting(request) {
        case .notification:
            return nil
        case .refused(let response):
            return response
        case .method(let routed, let routedID):
            (method, id) = (routed, routedID)
        }

        switch method {
        case .initialize:
            return await initializeResponse(id: id, params: request.params, context: context)
        case .serverDiscover:
            return .success(id: id, result: mcpDiscoverResult(surface: await surface(context: context)))
        case .ping:
            return .success(id: id, result: .object([:]))
        case .initialized:
            // Normally a notification (handled above).  If a client sends it
            // with an id, ack with an empty result rather than erroring.
            return .success(id: id, result: .object([:]))
        case .toolsList:
            return mcpToolsListResponse(id: id, params: request.params, tools: tools, context: context)
        case .toolsCall:
            return await mcpToolsCallResponse(id: id, params: request.params, tools: tools, context: context)
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
            return resourceFailure(error, id: id, context: context, fallback: "Failed to list resources.")
        }
    }

    /// One mapping for both resource methods (#2340). A refusal the agent can
    /// act on (an ineligible account, an unknown or inaccessible resource) is
    /// `invalidParams` with its reason. Anything else is a server fault: it
    /// stays opaque to the agent and reaches the log, as on the tools path, so a
    /// database grant error on the `.mcp` role leaves a trace.
    private func resourceFailure(
        _ error: any Error, id: JSONRPCID, context: ToolContext, fallback: String
    ) -> JSONRPCResponse {
        switch error as? MCPToolError {
        case .invalidArguments(let message), .notAuthorized(let message):
            return .failure(id: id, error: .invalidParams(message))
        case .unknownTool:
            return .failure(id: id, error: .invalidParams("Unknown resource."))
        case .executionFailed(let detail):
            context.logger.error("MCP \(fallback) \(detail)")
            return .failure(id: id, error: .internalError(detail))
        case nil:
            context.logger.error("MCP \(fallback) \(error)")
            return .failure(id: id, error: .internalError(fallback))
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
        } catch {
            return resourceFailure(error, id: id, context: context, fallback: "Failed to read resource.")
        }
    }

    /// What this server advertises to the caller, shared by the legacy
    /// `initialize` handshake and the modern `server/discover` method so both
    /// describe the same server — including the caller's own per-course
    /// authoring guidance.
    ///
    /// Layering that guidance is best-effort: a lookup failure, a context-free
    /// dispatch, or an app with no database configured (the transport unit
    /// tests — where `request.db` would fatalError, hence the explicit
    /// `hasDatabase` check) degrades to the house text rather than failing.
    private func surface(context: ToolContext?) async -> MCPInitializeSurface {
        var instructions = MCPServerInstructions.text
        if let context, context.hasDatabase {
            let guidance = (try? await mcpCourseGuidance(forSubject: context.subject, db: context.db)) ?? []
            instructions = MCPServerInstructions.text(withCourseGuidance: guidance)
        }
        return MCPInitializeSurface(
            capabilities: .v1,
            serverInfo: serverInfo,
            instructions: instructions,
            logLabel: ContentMCPSurface.logLabel)
    }

    private func initializeResponse(
        id: JSONRPCID, params: JSONValue?, context: ToolContext?
    ) async -> JSONRPCResponse {
        mcpInitializeResponse(
            id: id, params: params,
            surface: await surface(context: context),
            logger: context?.logger)
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
