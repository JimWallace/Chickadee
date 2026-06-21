// Route-level tests for the /mcp Streamable HTTP endpoint: JSON responses,
// notification acknowledgement, method restrictions, and the DNS-rebinding
// Origin guard.  The route is mounted behind a stub principal middleware that
// stands in for MCPBearerAuthMiddleware (which the live server uses); these
// tests exercise transport behaviour, not authentication — see
// MCPBearerAuthMiddlewareTests and MCPEndToEndTests for the auth path.

import Testing
import VaporTesting

@testable import APIServer

@Suite struct MCPEndpointTests {
    /// Stands in for MCPBearerAuthMiddleware: sets an authenticated principal so
    /// the transport can build a ToolContext without a real token.
    private struct StubPrincipalMiddleware: AsyncMiddleware {
        let principal: MCPPrincipal
        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            request.mcpPrincipal = principal
            return try await next.respond(to: request)
        }
    }

    private func makeApp(configuration: MCPRoutes.Configuration = .init()) async throws -> Application {
        let app = try await Application.make(.testing)
        let dispatcher = MCPDispatcher(serverInfo: MCPServerInfo(name: "Chickadee MCP", version: "test"))
        let principal = MCPPrincipal(subject: "tester", grantedScopes: Set(ContentScope.allCases))
        try app.grouped(StubPrincipalMiddleware(principal: principal))
            .register(collection: MCPRoutes(dispatcher: dispatcher, configuration: configuration))
        return app
    }

    private let jsonHeaders: HTTPHeaders = ["Content-Type": "application/json"]

    @Test func postInitializeReturnsJSONResult() async throws {
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            try await app.testing().test(
                .POST, "/mcp", headers: jsonHeaders, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)
                #expect(String(buffer: res.body).contains("2025-11-25"))
            }
        }
    }

    @Test func postNotificationReturns202WithNoBody() async throws {
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: jsonHeaders, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .accepted)
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    @Test func unparseableBodyReturns400ParseError() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/mcp", headers: jsonHeaders, body: ByteBuffer(string: "not json")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(String(buffer: res.body).contains("-32700"))
            }
        }
    }

    @Test func getReturns405() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/mcp") { res async in
                #expect(res.status == .methodNotAllowed)
            }
        }
    }

    @Test func supportedProtocolVersionHeaderIsAccepted() async throws {
        try await withApp(try await makeApp()) { app in
            for version in ["2025-11-25", "2025-06-18"] {
                var headers = jsonHeaders
                headers.add(name: "MCP-Protocol-Version", value: version)
                let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
                try await app.testing().test(
                    .POST, "/mcp", headers: headers, body: ByteBuffer(string: body)
                ) { res async in
                    #expect(res.status == .ok)
                }
            }
        }
    }

    @Test func unsupportedProtocolVersionHeaderReturns400() async throws {
        // §Protocol Version Header: an unsupported declared revision is
        // rejected with 400 before the body is ever read. (An absent header
        // is accepted — every other test in this suite covers that path.)
        try await withApp(try await makeApp()) { app in
            var headers = jsonHeaders
            headers.add(name: "MCP-Protocol-Version", value: "1999-01-01")
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: headers, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .badRequest)
                let responseBody = String(buffer: res.body)
                #expect(responseBody.contains("-32600"))
                #expect(responseBody.contains("MCP-Protocol-Version"))
            }
        }
    }

    @Test func presentOriginWithEmptyAllowlistIsAllowed() async throws {
        // Default config has an empty origin allowlist → "allow any", so a
        // request carrying an Origin (e.g. a browser MCP client) is not
        // rejected out of the box. Regression guard for the empty-set check.
        try await withApp(try await makeApp()) { app in
            let headers: HTTPHeaders = [
                "Content-Type": "application/json",
                "Origin": "https://some-client.example",
            ]
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: headers, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func disallowedOriginReturns403() async throws {
        let configuration = MCPRoutes.Configuration(allowedOrigins: ["https://allowed.example"])
        try await withApp(try await makeApp(configuration: configuration)) { app in
            let headers: HTTPHeaders = [
                "Content-Type": "application/json",
                "Origin": "https://evil.example",
            ]
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: headers, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }
}
