// Route-level tests for the /admin-mcp Streamable HTTP endpoint: JSON responses,
// notification ack, method restrictions, and the DNS-rebinding Origin guard.
// Mounted behind a stub principal middleware standing in for
// AdminMCPBearerAuthMiddleware (the auth path is covered in AdminMCPBearerTests).

import Testing
import VaporTesting

@testable import APIServer

@Suite struct AdminMCPEndpointTests {
    private struct StubPrincipalMiddleware: AsyncMiddleware {
        let principal: AdminMCPPrincipal
        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            request.adminMcpPrincipal = principal
            return try await next.respond(to: request)
        }
    }

    private func makeApp(configuration: MCPRoutes.Configuration = .init()) async throws -> Application {
        let app = try await Application.make(.testing)
        let dispatcher = AdminMCPDispatcher(
            serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test"),
            tools: AdminMCPToolCatalog.live)
        let principal = AdminMCPPrincipal(subject: "tester", grantedScopes: Set(DiagnosticScope.allCases))
        try app.grouped(StubPrincipalMiddleware(principal: principal))
            .register(collection: AdminMCPRoutes(dispatcher: dispatcher, configuration: configuration))
        return app
    }

    private let jsonHeaders: HTTPHeaders = ["Content-Type": "application/json"]

    @Test func postInitializeReturnsToolsOnlyResult() async throws {
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            try await app.testing().test(
                .POST, "/admin-mcp", headers: jsonHeaders, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .ok)
                let text = String(buffer: res.body)
                #expect(text.contains("2025-11-25"))
                #expect(text.contains("ADMIN DIAGNOSTIC"))
            }
        }
    }

    @Test func postNotificationReturns202() async throws {
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            try await app.testing().test(
                .POST, "/admin-mcp", headers: jsonHeaders, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .accepted)
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    @Test func unparseableBodyReturns400() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/admin-mcp", headers: jsonHeaders, body: ByteBuffer(string: "not json")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(String(buffer: res.body).contains("-32700"))
            }
        }
    }

    @Test func getReturns405() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/admin-mcp") { res async in
                #expect(res.status == .methodNotAllowed)
            }
        }
    }

    @Test func disallowedOriginReturns403() async throws {
        let configuration = MCPRoutes.Configuration(allowedOrigins: ["https://allowed.example"])
        try await withApp(try await makeApp(configuration: configuration)) { app in
            let headers: HTTPHeaders = [
                "Content-Type": "application/json", "Origin": "https://evil.example",
            ]
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            try await app.testing().test(
                .POST, "/admin-mcp", headers: headers, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }
}
