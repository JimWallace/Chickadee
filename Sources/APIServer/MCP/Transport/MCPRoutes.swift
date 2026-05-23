// APIServer/MCP/Transport/MCPRoutes.swift
//
// The MCP Streamable HTTP transport, mounted at a single endpoint (`/mcp`).
// v1 returns plain JSON synchronously; there is no server-initiated SSE stream
// yet, so GET and DELETE return 405.
//
// DNS-rebinding mitigation (transport spec §Security): the `Origin` header is
// validated against an allowlist (403 on mismatch), and — because Vapor does
// not do this by default — the `Host` header is pinned to an allowlist too.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

import Foundation
import Vapor

struct MCPRoutes: RouteCollection {
    let dispatcher: MCPDispatcher
    let configuration: Configuration

    /// Transport-level guards.  Both allowlists default to empty, which means
    /// "allow any" — production configuration supplies explicit values.
    struct Configuration: Sendable {
        /// Permitted `Host` header values (`host[:port]`, compared lowercased).
        /// Empty disables the check.
        var allowedHosts: Set<String>
        /// Permitted `Origin` header values.  A request whose `Origin` is
        /// present and not listed is rejected (403).  An absent `Origin` is
        /// allowed, so non-browser clients (MCP Inspector, curl) still work.
        var allowedOrigins: Set<String>

        init(allowedHosts: Set<String> = [], allowedOrigins: Set<String> = []) {
            self.allowedHosts = allowedHosts
            self.allowedOrigins = allowedOrigins
        }
    }

    func boot(routes: RoutesBuilder) throws {
        let group = routes.grouped("mcp")
        group.post(use: handlePost)
        group.on(.GET, use: streamingUnsupported)
        group.on(.DELETE, use: streamingUnsupported)
    }

    // MARK: - Handlers

    func handlePost(req: Request) async throws -> Response {
        try validateHost(req)
        try validateOrigin(req)

        let rpcRequest: JSONRPCRequest
        do {
            rpcRequest = try decodeRequest(req)
        } catch {
            // Unparseable body: HTTP 400 carrying a JSON-RPC parse error with a
            // null id (the request id is unknowable).
            return try jsonResponse(.failure(id: .null, error: .parseError()), status: .badRequest)
        }

        guard let rpcResponse = await dispatcher.dispatch(rpcRequest) else {
            // A notification was accepted; the spec mandates 202 with no body.
            return Response(status: .accepted)
        }
        return try jsonResponse(rpcResponse, status: .ok)
    }

    func streamingUnsupported(req: Request) async throws -> Response {
        // v1 offers no server-initiated SSE stream at this endpoint.
        // TODO: implement the Streamable HTTP GET/DELETE flows if a tool needs
        // server-to-client streaming.
        // https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
        throw Abort(.methodNotAllowed)
    }

    // MARK: - Guards

    private func validateHost(_ req: Request) throws {
        guard !configuration.allowedHosts.isEmpty else { return }
        let host = req.headers.first(name: "Host")?.lowercased() ?? ""
        guard configuration.allowedHosts.contains(host) else {
            throw Abort(.forbidden, reason: "Host header is not in the allowlist.")
        }
    }

    private func validateOrigin(_ req: Request) throws {
        guard let origin = req.headers.first(name: "Origin") else { return }
        guard configuration.allowedOrigins.contains(origin) else {
            throw Abort(.forbidden, reason: "Origin is not in the allowlist.")
        }
    }

    // MARK: - Body / response helpers

    private func decodeRequest(_ req: Request) throws -> JSONRPCRequest {
        guard var buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Missing request body.")
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(JSONRPCRequest.self, from: Data(bytes))
    }

    private func jsonResponse(_ payload: JSONRPCResponse, status: HTTPResponseStatus) throws -> Response {
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
