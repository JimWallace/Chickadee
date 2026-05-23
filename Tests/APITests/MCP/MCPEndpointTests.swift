// Route-level tests for the /mcp Streamable HTTP endpoint: JSON responses,
// notification acknowledgement, method restrictions, and the DNS-rebinding
// Origin guard.  The route collection is registered on a throwaway test app —
// the live server does not mount /mcp until the bearer middleware gates it.

import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPEndpointTests {
    private func makeApp(configuration: MCPRoutes.Configuration = .init()) async throws -> Application {
        let app = try await Application.make(.testing)
        let dispatcher = MCPDispatcher(serverInfo: MCPServerInfo(name: "Chickadee MCP", version: "test"))
        try app.register(collection: MCPRoutes(dispatcher: dispatcher, configuration: configuration))
        return app
    }

    private let jsonHeaders: HTTPHeaders = ["Content-Type": "application/json"]

    @Test func postInitializeReturnsJSONResult() async throws {
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            try await app.testable().test(
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
            try await app.testable().test(
                .POST, "/mcp", headers: jsonHeaders, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .accepted)
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    @Test func unparseableBodyReturns400ParseError() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .POST, "/mcp", headers: jsonHeaders, body: ByteBuffer(string: "not json")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(String(buffer: res.body).contains("-32700"))
            }
        }
    }

    @Test func getReturns405() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/mcp") { res async in
                #expect(res.status == .methodNotAllowed)
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
            try await app.testable().test(
                .POST, "/mcp", headers: headers, body: ByteBuffer(string: body)
            ) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }
}
