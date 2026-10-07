// APIServer/MCP/Admin/AdminMCPRoutes.swift
//
// The MCP Streamable HTTP transport for the admin diagnostic surface, mounted at
// `/admin-mcp` (NOT `/admin/mcp`, which is the admin web page for content-MCP
// service accounts). Like `MCPRoutes` without the live-progress streaming
// special case (the admin surface has no streaming tool). The POST itself —
// guards, decoding, era resolution, response framing — is
// `MCPTransport.serve`, shared with the content endpoint (#2339).
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
        try await transport.serve(req) { rpcRequest, era in
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
            return .rpc(await dispatcher.dispatch(rpcRequest, context: context, era: era))
        }
    }

    func streamingUnsupported(req: Request) async throws -> Response {
        throw Abort(.methodNotAllowed)
    }
}
