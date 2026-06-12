// Tests for MCP_MODE=read_only: the endpoint is mounted and authenticates
// normally, but the server clamps every request's scopes to {content:read}.
// The clamp lives in MCPBearerAuthMiddleware and applies per request, so even a
// content:write token minted while the server was read_write loses write the
// instant the operator flips to read_only — no token revocation needed.

import Fluent
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPReadOnlyModeTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    /// Builds a test app in read_only mode with the real MCP wiring mounted and
    /// a token authority attached (issuer/resource matched to minted tokens).
    private func makeReadOnlyApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            mode: .readOnly, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused",
            issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    private func post(_ app: Application, body: String, token: String) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"],
            body: ByteBuffer(string: body))
    }

    @Test func writeToolWithWriteScopedTokenIsForbiddenInReadOnly() async throws {
        let (app, authority) = try await makeReadOnlyApp()
        try await withApp(app) { app in
            // Token carries content:write, but read_only clamps it away, so the
            // write tool is rejected at the transport with 403 insufficient_scope.
            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_assignment","arguments":{"assignmentPublicID":"ABC123","isOpen":true}}}
                """#
            let res = try await post(app, body: body, token: token)
            #expect(res.status == .forbidden)
            #expect(res.headers.first(name: .wwwAuthenticate)?.contains("insufficient_scope") == true)
        }
    }

    @Test func toolsListWithWriteScopedTokenHidesWriteToolsInReadOnly() async throws {
        let (app, authority) = try await makeReadOnlyApp()
        try await withApp(app) { app in
            // Even a write-bearing token sees only read tools in read_only mode,
            // because the bearer clamp strips write before tools/list filters.
            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, token: token)
            #expect(res.status == .ok)
            let text = String(buffer: res.body)
            #expect(text.contains("list_assignments"))
            #expect(text.contains("get_assignment"))
            #expect(!text.contains("update_assignment"))
            #expect(!text.contains("create_assignment"))
            #expect(!text.contains("clone_assignment"))
        }
    }

    @Test func readToolStillSucceedsInReadOnly() async throws {
        let (app, authority) = try await makeReadOnlyApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let agent = try await makeTestUser(on: app, username: "agent", role: "mcp")
            try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_ro", courseID: courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "setup_ro", courseID: courseID, title: "Tasks")

            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_assignments","arguments":{"courseCode":"CS246"}}}
                """#
            let res = try await post(app, body: body, token: token)
            #expect(res.status == .ok)
            let text = String(buffer: res.body)
            #expect(text.contains("CS246"))
            #expect(text.contains("Tasks"))
        }
    }

    @Test func discoveryMetadataIsReachableInReadOnly() async throws {
        let (app, _) = try await makeReadOnlyApp()
        try await withApp(app) { app in
            try await app.testable().test(.GET, "/.well-known/oauth-protected-resource") { res async in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"resource\""))
            }
        }
    }
}
