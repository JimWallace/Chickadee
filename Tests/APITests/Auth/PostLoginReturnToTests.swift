// Tests/APITests/Auth/PostLoginReturnToTests.swift
//
// `postLoginRedirect` honours the MCP OAuth `returnTo` session value only when
// it is a plain server-relative path (`isSafeLocalPath`). A browser reads a
// backslash as a slash, so `/\evil.example` is the same off-site target as
// `//evil.example`; both must fall back to the normal post-login page.
//
// The good value is queued by the real flow: an unauthenticated GET of
// /oauth/authorize stores the request in the session and sends the browser to
// /login. The routes that write the value today only ever store an
// /oauth/authorize path, so the bad values are queued by a test-only route that
// writes the same session key. The check under test is the one at sign-in,
// whatever wrote the value.

import ChickadeeTestSupport
import Core
import Crypto
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct PostLoginReturnToTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let clientID = "return-to-agent"
    private let redirectURI = "https://app.example/callback"
    private let username = "return_to_prof"
    private let password = "testpassword"

    /// Path of the test-only route that queues `?to=` as the returnTo value.
    private static let queuePath = "/test-only/queue-return-to"

    private func makeOAuthApp() async throws -> Application {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        app.mcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.get("test-only", "queue-return-to") { req -> HTTPStatus in
            req.session.data[MCPOAuthRoutes.returnToSessionKey] = req.query[String.self, at: "to"]
            return .ok
        }
        return app
    }

    private var authorizePath: String {
        let verifier = "abcdefghijklmnopqrstuvwxyz0123456789-._~ABCDEFGH"
        var components = URLComponents()
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "content:read"),
            URLQueryItem(name: "state", value: "xyz"),
            URLQueryItem(
                name: "code_challenge",
                value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.string ?? "/oauth/authorize"
    }

    /// Creates the account and the OAuth client. The sign-in that creates the
    /// account is discarded, so each test starts from a signed-out browser.
    private func seed(_ app: Application) async throws {
        try await MCPOAuthClient(clientID: clientID, name: "Return-To Agent", redirectURIs: [redirectURI])
            .save(on: app.db)
        _ = try await loginUser(username: username, password: password, role: "instructor", on: app)
    }

    /// Sends a signed-out GET to `path` and returns the session cookie it sets.
    private func queue(_ path: String, on app: Application) async throws -> String {
        var cookie = ""
        try await app.asyncTest(
            .GET, path,
            afterResponse: { res in
                if let c = res.headers.first(name: .setCookie) { cookie = c }
            })
        if cookie.isEmpty { throw IssueRecorded("GET \(path) set no session cookie") }
        return cookie
    }

    /// Signs in within `cookie`'s session and returns the Location header.
    private func signIn(cookie: String, on app: Application) async throws -> String? {
        let (token, loginCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, "/login",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: loginCookie)
                try req.content.encode(
                    ["username": username, "password": password, "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    @Test func aQueuedAuthorizeRequestIsHonouredAfterSignIn() async throws {
        let app = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seed(app)
            let path = authorizePath
            var bounced: String?
            var cookie = ""
            try await app.asyncTest(
                .GET, path,
                afterResponse: { res in
                    bounced = res.headers.first(name: .location)
                    if let c = res.headers.first(name: .setCookie) { cookie = c }
                })
            #expect(bounced == "/login")
            #expect(!cookie.isEmpty)
            #expect(try await signIn(cookie: cookie, on: app) == path)
        }
    }

    @Test func aGoodQueuedPathIsHonoured() async throws {
        let app = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seed(app)
            let cookie = try await queue("\(Self.queuePath)?to=%2Fcourses%2Fx", on: app)
            #expect(try await signIn(cookie: cookie, on: app) == "/courses/x")
        }
    }

    @Test(arguments: ["/\\evil.example", "//evil.example", "https://evil.example", "/oauth\\..\\x"])
    func anOffSiteQueuedPathFallsBack(_ bad: String) async throws {
        let app = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seed(app)
            let encoded = bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let cookie = try await queue("\(Self.queuePath)?to=\(encoded)", on: app)
            let location = try #require(try await signIn(cookie: cookie, on: app))
            #expect(location != bad)
            #expect(isSafeLocalPath(location), "fell back to \(location)")
            #expect(!location.contains("evil"))
        }
    }
}
