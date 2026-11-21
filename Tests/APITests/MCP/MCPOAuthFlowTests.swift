// End-to-end tests for the Phase-2 browser OAuth flow: an instructor consents
// at /oauth/authorize, the client exchanges the PKCE code at /oauth/token for a
// short access token + a rotating refresh token, the access token works against
// /mcp, and the refresh token rotates.  Plus the guard rails: PKCE mismatch,
// deny, and the instructor/admin-only consent gate.

import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite struct MCPOAuthFlowTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let clientID = "test-agent"
    private let clientName = "Test Agent"
    private let redirectURI = "https://app.example/callback"

    private func makeOAuthApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    private func seedClient(_ app: Application) async throws {
        try await MCPOAuthClient(clientID: clientID, name: clientName, redirectURIs: [redirectURI])
            .save(on: app.db)
    }

    private func authorizePath(scope: String) -> String {
        mcpAuthorizePath(clientID: clientID, redirectURI: redirectURI, scope: scope)
    }

    /// Renders the consent screen (authenticated) and returns its single-use
    /// `request_token`.
    private func mintConsentToken(
        _ app: Application, cookie: String, scope: String
    ) async throws -> String {
        try await mintMCPConsentToken(app, cookie: cookie, authorizePath: authorizePath(scope: scope))
    }

    /// Runs the consent step (GET to mint the token, then a cookie-less POST) and
    /// returns the POST response (a 303 to the client).
    private func consent(
        _ app: Application, cookie: String, scope: String, decision: String
    ) async throws -> TestResponse {
        try await mcpConsent(app, cookie: cookie, authorizePath: authorizePath(scope: scope), decision: decision)
    }

    @Test func authorizationCodeThenRefreshFlow() async throws {
        let (app, authority) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            // Content consent requires per-course staff now (#417); enrol prof.
            try await enrollAsTestInstructor(username: "prof", on: app)

            // Consent → authorization code.
            let consentRes = try await consent(
                app, cookie: cookie, scope: "content:read content:write", decision: "authorize")
            #expect(consentRes.status == .seeOther)
            let location = consentRes.headers.first(name: .location)
            #expect(queryValue("state", in: location) == "xyz")
            // RFC 9207: every authorization response self-identifies its issuer.
            #expect(queryValue("iss", in: location) == issuer)
            let code = try #require(queryValue("code", in: location))

            // Code → access + refresh.
            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID,
                    "code_verifier": mcpTestCodeVerifier,
                ])
            #expect(tokenRes.status == .ok)
            let accessToken = try #require(jsonField("access_token", in: tokenRes))
            let refreshToken = try #require(jsonField("refresh_token", in: tokenRes))

            // Access token represents the human, attributed to the agent.
            let claims = try await authority.verify(accessToken)
            #expect(claims.sub.value == "prof")
            #expect(claims.clientID == clientID)
            #expect(claims.agentName == clientName)
            #expect(claims.scopes.contains("content:write"))

            // The access token actually works against /mcp.
            let mcpRes = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(accessToken)"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(mcpRes.status == .ok)
            #expect(mcpRes.body.string.contains("list_assignments"))

            // Refresh rotates to a fresh pair.
            let refreshRes = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": refreshToken])
            #expect(refreshRes.status == .ok)
            let rotated = try #require(jsonField("refresh_token", in: refreshRes))
            #expect(rotated != refreshToken)
            let newAccess = try #require(jsonField("access_token", in: refreshRes))
            #expect(try await authority.verify(newAccess).sub.value == "prof")
        }
    }

    /// The consent grant and the first token issuance must both leave an audit
    /// trail — the gap behind "I authorized MCP access but the audit log was
    /// empty".  (Routine refresh rotation is intentionally NOT audited.)
    @Test func consentAndTokenIssuanceAreAudited() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)

            let consentRes = try await consent(
                app, cookie: cookie, scope: "content:read content:write", decision: "authorize")
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
            _ = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID,
                    "code_verifier": mcpTestCodeVerifier,
                ])

            let consentEntry = try #require(
                await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.mcpConsentGranted.rawValue).first())
            #expect(consentEntry.actorUsername == "prof")
            #expect(consentEntry.metadata?.contains(clientID) == true)

            let tokenEntry = try #require(
                await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.mcpTokenIssued.rawValue).first())
            #expect(tokenEntry.actorUsername == "prof")
        }
    }

    @Test func refreshAfterRoleDowngradeIsRejectedAndRevokesGrant() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let consentRes = try await consent(
                app, cookie: cookie, scope: "content:read content:write", decision: "authorize")
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID,
                    "code_verifier": mcpTestCodeVerifier,
                ])
            let refreshToken = try #require(jsonField("refresh_token", in: tokenRes))

            // The instructor is demoted to student (role downgrade / repurpose).
            // Authority is per-course now (#417 Slice G2), so strip the enrollment
            // staff role — the global role no longer governs MCP eligibility.
            try await demoteToStudentEverywhere(username: "prof", on: app)

            // Refresh now fails, and the grant is revoked so a retry also fails.
            let refreshRes = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": refreshToken])
            #expect(refreshRes.status == .badRequest)
            #expect(jsonField("error", in: refreshRes) == "invalid_grant")
            let grant = try #require(await MCPGrant.query(on: app.db).first())
            #expect(grant.revoked)
        }
    }

    @Test func pkceMismatchIsRejected() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let consentRes = try await consent(
                app, cookie: cookie, scope: "content:read", decision: "authorize")
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))

            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID,
                    "code_verifier": "the-wrong-verifier-aaaaaaaaaaaaaaaaaaaaaaaa",
                ])
            #expect(tokenRes.status == .badRequest)
            #expect(tokenRes.body.string.contains("invalid_grant"))
        }
    }

    @Test func denyRedirectsWithAccessDenied() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let res = try await consent(
                app, cookie: cookie, scope: "content:read", decision: "deny")
            #expect(res.status == .seeOther)
            #expect(queryValue("error", in: res.headers.first(name: .location)) == "access_denied")
            // RFC 9207 requires `iss` on error responses too.
            #expect(queryValue("iss", in: res.headers.first(name: .location)) == issuer)
        }
    }

    @Test func authorizeSucceedsWithoutSessionCookieOnPost() async throws {
        // The Safari/ITP case: the cross-site consent POST carries no session
        // cookie. The single-use token alone must authenticate the consent.
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let token = try await mintConsentToken(
                app, cookie: cookie, scope: "content:read content:write")
            let res = try await submitMCPConsent(app, token: token, decision: "authorize", cookie: nil)
            #expect(res.status == .seeOther)
            #expect(queryValue("code", in: res.headers.first(name: .location)) != nil)
        }
    }

    @Test func unknownConsentTokenIsRejected() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let res = try await submitMCPConsent(
                app, token: "not-a-real-consent-token", decision: "authorize")
            #expect(res.status == .badRequest)
        }
    }

    @Test func consumedConsentTokenCannotBeReplayed() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let token = try await mintConsentToken(app, cookie: cookie, scope: "content:read")
            #expect(try await submitMCPConsent(app, token: token, decision: "authorize").status == .seeOther)
            // Single-use: replaying the same token is rejected.
            #expect(try await submitMCPConsent(app, token: token, decision: "authorize").status == .badRequest)
        }
    }

    @Test func expiredConsentTokenIsRejected() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            _ = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let prof = try #require(
                await APIUser.query(on: app.db).filter(\.$username == "prof").first())
            let token = "expired-consent-token-aaaaaaaaaaaaaaaaaaaaaaaa"
            try await MCPConsentRequest(
                tokenHash: sha256HexDigest(token),
                userID: try prof.requireID(),
                clientID: clientID,
                redirectURI: redirectURI,
                scope: "content:read",
                state: "xyz",
                codeChallenge: mcpTestCodeChallenge,
                codeChallengeMethod: "S256",
                expiresAt: Date().addingTimeInterval(-60)
            ).save(on: app.db)
            let res = try await submitMCPConsent(app, token: token, decision: "authorize")
            #expect(res.status == .badRequest)
        }
    }

    @Test func roleDowngradeBetweenConsentAndSubmitIsRejected() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let token = try await mintConsentToken(app, cookie: cookie, scope: "content:read")
            // Demote the consenting user after the screen rendered but before submit.
            // Authority is per-course now (#417 Slice G2) — strip the enrollment.
            try await demoteToStudentEverywhere(username: "prof", on: app)
            let res = try await submitMCPConsent(app, token: token, decision: "authorize")
            #expect(res.status == .forbidden)
        }
    }

    @Test func studentCannotAuthorize() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "student1", password: "testpassword", role: "student", on: app)
            try await app.asyncTest(
                .GET, authorizePath(scope: "content:read"),
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("instructors and admins"))
                    #expect(!body.contains("value=\"authorize\""))
                })
        }
    }

    /// Runs consent → code → token and returns the refresh token.
    private func obtainRefreshToken(_ app: Application, cookie: String) async throws -> String {
        let consentRes = try await consent(
            app, cookie: cookie, scope: "content:read", decision: "authorize")
        let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
        let tokenRes = try await tokenPost(
            app,
            fields: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": mcpTestCodeVerifier,
            ])
        return try #require(jsonField("refresh_token", in: tokenRes))
    }

    @Test func revokeEndpointStopsRefresh() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let refresh = try await obtainRefreshToken(app, cookie: cookie)

            let revokeRes = try await app.asyncSendRequest(
                .POST, "/oauth/revoke",
                beforeRequest: { req in try req.content.encode(["token": refresh], as: .urlEncodedForm) })
            #expect(revokeRes.status == .ok)

            let refreshRes = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": refresh])
            #expect(refreshRes.status == .badRequest)
            #expect(refreshRes.body.string.contains("invalid_grant"))
        }
    }

    @Test func replayedRefreshTokenRevokesGrant() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await enrollAsTestInstructor(username: "prof", on: app)
            let firstRefresh = try await obtainRefreshToken(app, cookie: cookie)

            // Legitimate rotation.
            let rotated = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": firstRefresh])
            #expect(rotated.status == .ok)
            let newRefresh = try #require(jsonField("refresh_token", in: rotated))

            // Replaying the spent token revokes the grant.
            let replay = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": firstRefresh])
            #expect(replay.status == .badRequest)
            #expect(replay.body.string.contains("invalid_grant"))

            // The otherwise-valid rotated token is now dead too.
            let afterRevoke = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": newRefresh])
            #expect(afterRevoke.status == .badRequest)
        }
    }

    @Test func connectedAgentsPageListsAndRevokes() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            // Phase 5: /agents is under the per-course-gated /instructor group.
            try await enrollAsTestInstructor(username: "prof", on: app)
            let refresh = try await obtainRefreshToken(app, cookie: cookie)

            let grantID = try #require(try await MCPGrant.query(on: app.db).first()).requireID()
            try await app.asyncTest(
                .GET, "/agents",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains(clientName))
                })

            let (csrf, bound) = try await csrfFields(for: "/agents", cookie: cookie, on: app)
            let revokeRes = try await app.asyncSendRequest(
                .POST, "/agents/\(grantID.uuidString)/revoke",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: bound)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                })
            #expect(revokeRes.status == .seeOther)

            let refreshRes = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": refresh])
            #expect(refreshRes.status == .badRequest)
        }
    }
}
