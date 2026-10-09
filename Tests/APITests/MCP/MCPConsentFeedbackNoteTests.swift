// The consent screen's access note must stay true for the grant it describes
// (docs/ai-assisted-feedback.md). A grant without the feedback scopes still
// says the agent cannot reach student data; a grant with `feedback:read` says
// what it can read instead, so the note never contradicts the scope list above
// it.

import Core
import Crypto
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct MCPConsentFeedbackNoteTests {
    private let clientID = "consent-note-agent"
    private let redirectURI = "https://app.example/callback"

    private func consentHTML(scope: String) async throws -> String {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused",
            issuer: "https://chickadee.example", resource: "https://chickadee.example/mcp")
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        app.mcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        var html = ""
        try await withApp(app) { app in
            try await MCPOAuthClient(clientID: clientID, name: "Note Agent", redirectURIs: [redirectURI])
                .save(on: app.db)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            var components = URLComponents()
            components.path = "/oauth/authorize"
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "state", value: "xyz"),
                URLQueryItem(name: "code_challenge", value: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            let path = try #require(components.string)
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in html = res.body.string })
        }
        return html
    }

    @Test func aContentOnlyGrantSaysTheAgentCannotReachStudentData() async throws {
        let html = try await consentHTML(scope: "content:read content:write")
        #expect(html.contains("It cannot access student data"))
        #expect(!html.contains("written answers"))
    }

    @Test func aFeedbackGrantSaysWhatTheAgentCanRead() async throws {
        let html = try await consentHTML(scope: "content:read feedback:read")
        #expect(!html.contains("It cannot access student data"))
        #expect(html.contains("only in assignments where AI-assisted feedback is on"))
    }
}
