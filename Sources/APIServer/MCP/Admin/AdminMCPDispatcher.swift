// APIServer/MCP/Admin/AdminMCPDispatcher.swift
//
// Routes a decoded JSON-RPC message to its handler for the admin diagnostic
// surface and produces the response (or nil, for notifications). The routing,
// tools/list and tools/call code is shared with `MCPDispatcher` (#2339); the
// admin surface's own steps around a call are `AdminMCPSurface`. It serves
// tools only (no resources capability).

import Core
import Foundation

struct AdminMCPDispatcher: Sendable {
    let serverInfo: MCPServerInfo
    let tools: DiagnosticToolRegistry

    init(serverInfo: MCPServerInfo, tools: DiagnosticToolRegistry = DiagnosticToolRegistry([])) {
        self.serverInfo = serverInfo
        self.tools = tools
    }

    /// Routes one message and, for a modern-era request, stamps the modern
    /// result envelope (`resultType` + server `_meta`) on the way out. `era`
    /// defaults to legacy so non-transport callers keep the historical shape.
    func dispatch(
        _ request: JSONRPCRequest, context: AdminToolContext? = nil, era: MCPEra = .legacy
    ) async -> JSONRPCResponse? {
        guard let response = await route(request, context: context) else { return nil }
        return mcpModernized(response, era: era, serverInfo: serverInfo)
    }

    private func route(_ request: JSONRPCRequest, context: AdminToolContext?) async -> JSONRPCResponse? {
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
            return initializeResponse(id: id, params: request.params, context: context)
        case .serverDiscover:
            return .success(id: id, result: mcpDiscoverResult(surface: surface))
        case .ping:
            return .success(id: id, result: .object([:]))
        case .initialized:
            return .success(id: id, result: .object([:]))
        case .toolsList:
            return mcpToolsListResponse(id: id, params: request.params, tools: tools, context: context)
        case .toolsCall:
            return await mcpToolsCallResponse(id: id, params: request.params, tools: tools, context: context)
        case .resourcesList, .resourcesRead:
            // The admin surface advertises tools only (no resources capability).
            return .failure(id: id, error: .methodNotFound(request.method))
        }
    }

    /// What this surface advertises, shared by the legacy `initialize`
    /// handshake and the modern `server/discover` method. Unlike the content
    /// surface, nothing here is per-caller — the diagnostic instructions are
    /// static — so it is a stored property rather than a lookup.
    private var surface: MCPInitializeSurface {
        MCPInitializeSurface(
            capabilities: .toolsOnly,
            serverInfo: serverInfo,
            instructions: AdminMCPServerInstructions.text,
            logLabel: AdminMCPSurface.logLabel)
    }

    private func initializeResponse(
        id: JSONRPCID, params: JSONValue?, context: AdminToolContext?
    ) -> JSONRPCResponse {
        mcpInitializeResponse(
            id: id, params: params, surface: surface, logger: context?.logger)
    }
}
