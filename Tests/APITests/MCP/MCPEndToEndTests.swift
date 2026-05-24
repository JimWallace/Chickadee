// End-to-end tests for the live /mcp endpoint: a token minted by the authority
// flows through MCPBearerAuthMiddleware into the dispatcher and a tool, and the
// per-tool scope gate surfaces as HTTP 403.  Enabling MCP in the test AppConfig
// drives the real `registerMCPRoutes` wiring (the same path the server uses).

import Fluent
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPEndToEndTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    /// Builds a test app with MCP enabled so `registerMCPRoutes` mounts the real
    /// bearer-gated /mcp transport + discovery metadata, then attaches a token
    /// authority (matching issuer/resource) the minted tokens validate against.
    private func makeMCPApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            enabled: true, allowedHosts: [], allowedOrigins: [],
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

    @Test func listAssignmentsWithFullScopeSucceeds() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            // The token subject is a real account enrolled in the course it acts on.
            let agent = try await makeTestUser(on: app, username: "agent", role: "mcp")
            try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_e2e", courseID: courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "setup_e2e", courseID: courseID, title: "Tasks")

            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_assignments","arguments":{"courseCode":"CS246"}}}
                """#
            let res = try await post(app, body: body, token: token)
            #expect(res.status == .ok)
            let text = String(buffer: res.body)
            #expect(text.contains("CS246"))
            #expect(text.contains("Tasks"))
        }
    }

    @Test func listAssignmentsForUnenrolledCourseIsDeniedInResult() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            // The agent exists but is NOT enrolled in CS246.
            _ = try await makeTestUser(on: app, username: "agent", role: "mcp")
            try await makeTestSetup(on: app, id: "setup_deny", courseID: courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "setup_deny", courseID: courseID, title: "Tasks")

            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_assignments","arguments":{"courseCode":"CS246"}}}
                """#
            let res = try await post(app, body: body, token: token)
            // The token is valid (200), but the tool reports an authorization
            // failure in-result rather than leaking the course's assignments.
            #expect(res.status == .ok)
            let text = String(buffer: res.body)
            #expect(text.contains("\"isError\":true"))
            #expect(text.contains("not enrolled"))
            #expect(!text.contains("Tasks"))
        }
    }

    @Test func writeToolWithReadOnlyTokenIsForbidden() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = #"""
                {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_assignment","arguments":{"assignmentPublicID":"ABC123","isOpen":true}}}
                """#
            let res = try await post(app, body: body, token: token)
            #expect(res.status == .forbidden)
            #expect(res.headers.first(name: .wwwAuthenticate)?.contains("insufficient_scope") == true)
        }
    }

    @Test func missingTokenIsUnauthorized() async throws {
        let (app, _) = try await makeMCPApp()
        try await withApp(app) { app in
            let res = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
            #expect(res.status == .unauthorized)
        }
    }

    @Test func toolsListWithValidTokenListsTools() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#, token: token)
            #expect(res.status == .ok)
            let text = String(buffer: res.body)
            #expect(text.contains("list_assignments"))
            #expect(text.contains("update_assignment"))
        }
    }

    @Test func discoveryMetadataIsReachableWithoutAToken() async throws {
        let (app, _) = try await makeMCPApp()
        try await withApp(app) { app in
            try await app.testable().test(.GET, "/.well-known/oauth-protected-resource") { res async in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"resource\""))
                #expect(body.contains("chickadee.example"))
            }
        }
    }
}
