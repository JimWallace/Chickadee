// APIServer/MCP/Transport/MCPDispatcher.swift
//
// Routes a decoded JSON-RPC message to its MCP handler and produces the
// response (or nil, for notifications).  This layer is transport-agnostic and
// Vapor-free: the HTTP route (MCPRoutes) owns framing, Host/Origin checks, and
// status codes; the dispatcher owns method semantics.
//
// v1 implements the lifecycle methods directly.  `tools/*` and `resources/*`
// return empty / placeholder results until the tool registry lands.
// https://modelcontextprotocol.io/specification/2025-11-25

import Core
import Foundation

/// Maps a JSON-RPC request to an MCP response.  Returns nil for notifications,
/// which receive no response per the spec.
struct MCPDispatcher: Sendable {
    let serverInfo: MCPServerInfo

    func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
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
            return .success(id: id, result: .object(["tools": .array([])]))
        case .resourcesList:
            return .success(id: id, result: .object(["resources": .array([])]))
        case .toolsCall, .resourcesRead:
            // TODO(step 4): dispatch to the tool registry / resource provider.
            // https://modelcontextprotocol.io/specification/2025-11-25/server/tools
            return .failure(id: id, error: .invalidParams("No tools or resources are registered yet."))
        }
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
