// APIServer/MCP/Admin/AdminMCPRoutes.swift
//
// The MCP Streamable HTTP transport for the admin diagnostic surface, mounted at
// `/admin-mcp` (NOT `/admin/mcp`, which is the admin web page for content-MCP
// service accounts).  Parallel to `MCPRoutes` but trimmed: no live-progress
// streaming special case (the admin surface has no streaming tool).  The
// transport mechanics — guards, decoding, era resolution, response framing —
// are `MCPTransport`, shared with the content endpoint.
//
// Mounted behind `AdminMCPBearerAuthMiddleware`, which authenticates the caller
// and populates `request.adminMcpPrincipal` before dispatch runs.

import Core
import Foundation
import Vapor

struct AdminMCPRoutes: RouteCollection {
    let dispatcher: AdminMCPDispatcher
    let configuration: MCPRoutes.Configuration

    private var transport: MCPTransport { MCPTransport(configuration: configuration) }

    func boot(routes: RoutesBuilder) throws {
        let group = routes.grouped("admin-mcp")
        group.post(use: handlePost)
        group.on(.GET, use: streamingUnsupported)
        group.on(.DELETE, use: streamingUnsupported)
    }

    func handlePost(req: Request) async throws -> Response {
        let rpcRequest: JSONRPCRequest
        let era: MCPEra
        switch try transport.admit(req) {
        case .rejected(let response):
            return response
        case .admitted(let admitted, let admittedEra):
            (rpcRequest, era) = (admitted, admittedEra)
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

        let rpcResponse = await dispatcher.dispatch(rpcRequest, context: context, era: era)
        return try transport.response(for: rpcResponse, era: era, req: req)
    }

    func streamingUnsupported(req: Request) async throws -> Response {
        throw Abort(.methodNotAllowed)
    }
}
