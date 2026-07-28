// APIServer/MCP/Admin/AdminMCPRoutes.swift
//
// The MCP Streamable HTTP transport for the admin diagnostic surface, mounted at
// `/admin-mcp` (NOT `/admin/mcp`, which is the admin web page for content-MCP
// service accounts).  Parallel to `MCPRoutes` but trimmed: no live-progress
// streaming special case (the admin surface has no streaming tool).  Reuses the
// generic SSE frame helpers from `MCPRoutes`.
//
// Mounted behind `AdminMCPBearerAuthMiddleware`, which authenticates the caller
// and populates `request.adminMcpPrincipal` before dispatch runs.

import Core
import Foundation
import Vapor

struct AdminMCPRoutes: RouteCollection {
    let dispatcher: AdminMCPDispatcher
    let configuration: MCPRoutes.Configuration

    func boot(routes: RoutesBuilder) throws {
        let group = routes.grouped("admin-mcp")
        group.post(use: handlePost)
        group.on(.GET, use: streamingUnsupported)
        group.on(.DELETE, use: streamingUnsupported)
    }

    func handlePost(req: Request) async throws -> Response {
        try validateHost(req)
        try validateOrigin(req)

        let rpcRequest: JSONRPCRequest
        do {
            rpcRequest = try decodeRequest(req)
        } catch {
            return try jsonResponse(.failure(id: .null, error: .parseError()), status: .badRequest)
        }

        // Dual-era, exactly as the content transport (#1218): modern `_meta`
        // selects the 2026-07-28 semantics, anything else stays legacy.
        let meta = MCPRequestMeta.extract(fromParams: rpcRequest.params)
        let era = mcpEra(of: meta, request: req)
        if era == .modern {
            if !rpcRequest.isNotification,
                let rejection = mcpModernTransportRejection(
                    request: req, rpc: rpcRequest, meta: meta, era: era)
            {
                let failure = JSONRPCResponse.failure(id: rpcRequest.id ?? .null, error: rejection)
                return try jsonResponse(failure, status: mcpResponseStatus(for: failure, era: era))
            }
        } else if let rejection = try protocolVersionRejection(req) {
            return rejection
        }

        guard let principal = req.adminMcpPrincipal else {
            throw Abort(
                .unauthorized,
                reason: "Admin MCP request reached the transport without an authenticated principal.")
        }
        let context = AdminToolContext(
            request: req,
            subject: principal.subject,
            grantedScopes: principal.grantedScopes,
            actingClientID: principal.actingClientID,
            actingClientName: principal.actingClientName
        )

        guard let rpcResponse = await dispatcher.dispatch(rpcRequest, context: context, era: era) else {
            return Response(status: .accepted)
        }
        if let error = rpcResponse.error, error.code == JSONRPCError.insufficientScopeCode {
            return try jsonResponse(
                rpcResponse, status: .forbidden, challenge: insufficientScopeChallenge(error))
        }
        let status = mcpResponseStatus(for: rpcResponse, era: era)
        guard status == .ok else {
            return try jsonResponse(rpcResponse, status: status)
        }
        if clientAcceptsEventStream(req) {
            return try eventStreamResponse(rpcResponse)
        }
        return try jsonResponse(rpcResponse, status: .ok)
    }

    func streamingUnsupported(req: Request) async throws -> Response {
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
        guard !configuration.allowedOrigins.isEmpty else { return }
        guard let origin = req.headers.first(name: "Origin") else { return }
        guard configuration.allowedOrigins.contains(origin) else {
            throw Abort(.forbidden, reason: "Origin is not in the allowlist.")
        }
    }

    private func protocolVersionRejection(_ req: Request) throws -> Response? {
        guard let version = req.headers.first(name: MCPHeader.protocolVersion),
            !MCPProtocol.supportedVersions.contains(version)
        else { return nil }
        return try jsonResponse(
            .failure(id: .null, error: .unsupportedProtocolVersion(requested: version)),
            status: .badRequest)
    }

    // MARK: - Body / response helpers

    private func decodeRequest(_ req: Request) throws -> JSONRPCRequest {
        guard var buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Missing request body.")
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(JSONRPCRequest.self, from: Data(bytes))
    }

    private func jsonResponse(
        _ payload: JSONRPCResponse, status: HTTPResponseStatus, challenge: String? = nil
    ) throws -> Response {
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.contentType = .json
        if let challenge {
            headers.replaceOrAdd(name: .wwwAuthenticate, value: challenge)
        }
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    private func clientAcceptsEventStream(_ req: Request) -> Bool {
        req.headers[.accept].contains { $0.lowercased().contains("text/event-stream") }
    }

    /// Frames a single JSON-RPC response as a one-shot SSE stream, reusing the
    /// generic frame/header helpers from the content transport.
    private func eventStreamResponse(_ payload: JSONRPCResponse) throws -> Response {
        let frame = try MCPRoutes.sseMessageFrame(encoding: payload)
        let response = Response(status: .ok, headers: MCPRoutes.sseHeaders())
        response.body = .init(stream: { writer in
            var buffer = ByteBufferAllocator().buffer(capacity: frame.utf8.count)
            buffer.writeString(frame)
            writer.write(.buffer(buffer)).whenComplete { _ in
                writer.write(.end, promise: nil)
            }
        })
        return response
    }

    private func insufficientScopeChallenge(_ error: JSONRPCError) -> String {
        var params: [String]
        if let url = configuration.resourceMetadataURL {
            params = ["Bearer resource_metadata=\"\(url)\"", "error=\"insufficient_scope\""]
        } else {
            params = ["Bearer error=\"insufficient_scope\""]
        }
        if case .string(let scope)? = error.data {
            params.append("scope=\"\(scope)\"")
        }
        return params.joined(separator: ", ")
    }
}
