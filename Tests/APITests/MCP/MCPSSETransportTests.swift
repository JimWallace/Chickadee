// Tests for the /mcp Streamable HTTP SSE response mode: when the client sends
// `Accept: text/event-stream`, the POST response is an SSE stream framing the
// same JSON-RPC response as an `event: message`; otherwise it stays plain JSON.
// Security-status responses (insufficient scope) are never masked behind a 200
// SSE body. Drives the real registerMCPRoutes wiring via an MCP-enabled config.

import Fluent
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPSSETransportTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    private func makeMCPApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused",
            issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    private func post(
        _ app: Application, body: String, token: String, accept: String
    ) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "Accept": accept,
            ],
            body: ByteBuffer(string: body))
    }

    @Test func toolsListOverSSEReturnsEventStream() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                token: token, accept: "application/json, text/event-stream")

            #expect(res.status == .ok)
            #expect(res.headers.contentType?.description.contains("text/event-stream") == true)
            // Proxy-buffering defeat header is present.
            #expect(res.headers.first(name: "X-Accel-Buffering") == "no")

            let body = res.body.string
            // SSE framing: a `message` event with a single data line, blank-line
            // terminated, carrying the JSON-RPC result with the tool catalogue.
            #expect(body.contains("event: message"))
            #expect(body.contains("data: "))
            #expect(body.hasSuffix("\n\n"))
            #expect(body.contains("list_assignments"))
            #expect(body.contains("\"jsonrpc\":\"2.0\""))
        }
    }

    @Test func defaultRequestStillReturnsPlainJSON() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            // No text/event-stream in Accept → unchanged plain-JSON behaviour.
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                token: token, accept: "application/json")

            #expect(res.status == .ok)
            #expect(res.headers.contentType == .json)
            let body = res.body.string
            #expect(!body.contains("event: message"))
            #expect(body.contains("list_assignments"))
        }
    }

    @Test func toolResultStreamsStructuredContent() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let agent = try await makeTestUser(on: app, username: "agent", role: "mcp")
            try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_sse", courseID: courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "setup_sse", courseID: courseID, title: "Tasks")

            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_assignments","arguments":{"courseCode":"CS246"}}}
                """#
            let res = try await post(
                app, body: body, token: token, accept: "text/event-stream")

            #expect(res.status == .ok)
            #expect(res.headers.contentType?.description.contains("text/event-stream") == true)
            let text = res.body.string
            #expect(text.contains("event: message"))
            #expect(text.contains("CS246"))
            #expect(text.contains("Tasks"))
        }
    }

    @Test func insufficientScopeStays403JSONEvenWhenSSERequested() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            // Read-only token calling a write tool, while asking for SSE: the
            // 403 must NOT be swallowed by a 200 SSE body — clients must see the
            // authorization failure at the transport layer.
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_assignment","arguments":{"assignmentPublicID":"ABC123","isOpen":true}}}
                """#
            let res = try await post(
                app, body: body, token: token, accept: "text/event-stream")

            #expect(res.status == .forbidden)
            #expect(res.headers.contentType?.description.contains("text/event-stream") != true)
            #expect(res.headers.first(name: .wwwAuthenticate)?.contains("insufficient_scope") == true)
        }
    }
}
