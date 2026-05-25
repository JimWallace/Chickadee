// Tests for RFC 7591 Dynamic Client Registration: POST /oauth/register creates
// a usable public OAuth client, validates redirect URIs, and the registered
// client is then recognized at /oauth/authorize.

import Fluent
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPDynamicRegistrationTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let redirectURI = "https://app.example/cb"

    private func makeApp() async throws -> Application {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        app.mcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        return app
    }

    private func register(_ app: Application, body: String) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/oauth/register",
            headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body))
    }

    private func jsonObject(_ res: XCTHTTPResponse) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8))) as? [String: Any]
    }

    @Test func registrationCreatesUsableClient() async throws {
        try await withApp(try await makeApp()) { app in
            let res = try await register(
                app, body: #"{"client_name":"My Agent","redirect_uris":["\#(redirectURI)"]}"#)
            #expect(res.status == .created)
            let object = jsonObject(res)
            let clientID = try #require(object?["client_id"] as? String)
            #expect(object?["token_endpoint_auth_method"] as? String == "none")

            let client = try #require(
                try await MCPOAuthClient.query(on: app.db).filter(\.$clientID == clientID).first())
            #expect(client.name == "My Agent")
            #expect(client.redirectURIs == [redirectURI])
            #expect(client.isPublic)
        }
    }

    @Test func registrationRejectsNonLocalHTTPRedirect() async throws {
        try await withApp(try await makeApp()) { app in
            let res = try await register(app, body: #"{"redirect_uris":["http://evil.example/cb"]}"#)
            #expect(res.status == .badRequest)
            #expect(res.body.string.contains("invalid_redirect_uri"))
        }
    }

    @Test func registrationRejectsEmptyRedirectURIs() async throws {
        try await withApp(try await makeApp()) { app in
            let res = try await register(app, body: #"{"client_name":"x","redirect_uris":[]}"#)
            #expect(res.status == .badRequest)
        }
    }

    @Test func registrationAllowsLocalhostHTTP() async throws {
        try await withApp(try await makeApp()) { app in
            let res = try await register(app, body: #"{"redirect_uris":["http://localhost:7777/cb"]}"#)
            #expect(res.status == .created)
        }
    }

    @Test func registeredClientIsAcceptedAtAuthorize() async throws {
        try await withApp(try await makeApp()) { app in
            let regRes = try await register(
                app, body: #"{"client_name":"Inspector","redirect_uris":["\#(redirectURI)"]}"#)
            let clientID = try #require(jsonObject(regRes)?["client_id"] as? String)

            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            var components = URLComponents()
            components.path = "/oauth/authorize"
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: "content:read"),
                URLQueryItem(name: "state", value: "s"),
                URLQueryItem(name: "code_challenge", value: "dummychallenge"),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            try await app.asyncTest(
                .GET, try #require(components.string),
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Inspector"))
                })
        }
    }
}
