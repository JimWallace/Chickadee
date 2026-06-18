// End-to-end auth tests for the mounted /admin-mcp endpoint: a real
// AdminMCPBearerAuthMiddleware in front of the transport, exercising token
// verification, the audience isolation that separates the admin surface from the
// content surface, and scope clamping.

import Core
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite(.serialized) struct AdminMCPBearerTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/admin-mcp"
    private let contentResource = "https://chickadee.example/mcp"

    /// Builds a test app with MCP mounted (which all-or-nothing mounts the admin
    /// /admin-mcp surface too) and the shared token authority installed, mirroring
    /// how runAPIServer wires it.  The admin resource is derived as
    /// `<origin>/admin-mcp`, matching `resource`.
    private func makeMountedApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: contentResource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    private func post(
        _ app: Application, body: String, bearer: String?
    ) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(.POST, "/admin-mcp") { req in
            req.headers.contentType = .json
            if let bearer { req.headers.add(name: .authorization, value: "Bearer \(bearer)") }
            req.body = ByteBuffer(string: body)
        }
    }

    private func adminToken(
        _ authority: MCPTokenAuthority, scopes: [String] = ["diagnostics:read"], audience: String
    ) async throws -> String {
        try await authority.mint(
            subject: "root", scopeStrings: scopes, issuer: issuer, audience: audience, ttlSeconds: 3600)
    }

    @Test func missingTokenReturns401() async throws {
        let (app, _) = try await makeMountedApp()
        try await withApp(app) { app in
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, bearer: nil)
            #expect(res.status == .unauthorized)
        }
    }

    @Test func validAdminTokenReachesDispatch() async throws {
        let (app, authority) = try await makeMountedApp()
        try await withApp(app) { app in
            let token = try await adminToken(authority, audience: resource)
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, bearer: token)
            #expect(res.status == .ok)
            #expect(res.body.string.contains("2025-11-25"))
        }
    }

    @Test func getDeploymentInfoOverBearerReportsReadOnly() async throws {
        let (app, authority) = try await makeMountedApp()
        try await withApp(app) { app in
            let token = try await adminToken(authority, audience: resource)
            let body =
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_deployment_info"}}"#
            let res = try await post(app, body: body, bearer: token)
            #expect(res.status == .ok)
            #expect(res.body.string.contains("read_only"))
        }
    }

    @Test func contentAudienceTokenIsRejected() async throws {
        // A token minted for the CONTENT resource must NOT authenticate against
        // the admin endpoint — this audience isolation is what keeps the two
        // surfaces separate even though they share a token format.
        let (app, authority) = try await makeMountedApp()
        try await withApp(app) { app in
            let token = try await adminToken(authority, audience: contentResource)
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, bearer: token)
            #expect(res.status == .unauthorized)
        }
    }

    @Test func tokenWithoutDiagnosticScopeIsForbidden() async throws {
        // Correct audience but no diagnostics:read scope → clamped to empty → 403.
        let (app, authority) = try await makeMountedApp()
        try await withApp(app) { app in
            let token = try await adminToken(authority, scopes: ["content:read"], audience: resource)
            let res = try await post(
                app, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, bearer: token)
            #expect(res.status == .forbidden)
        }
    }
}
