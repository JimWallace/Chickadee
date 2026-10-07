// Tests/APITests/GitHub/GitHubAccountLinkRoutesTests.swift
//
// Linking a GitHub account (docs/github-submissions.md slice 2): the account
// page section and its CSP allowance, the redirect to GitHub, the callback
// (state, code, exchange, revocation), the one-account-per-link rule,
// unlinking, the data export entry, the audit trail, and the rule that
// nothing changes while no App is registered. GitHub is faked throughout.

import ChickadeeTestSupport
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubAccountLinkRoutesTests {
    let app: Application
    let directory: URL
    /// What the fake GitHub saw: codes exchanged and tokens revoked.
    let exchanged = NIOLockedValueBox<[GitHubCodeExchange]>([])
    let revoked = NIOLockedValueBox<[String]>([])

    static let githubUser = GitHubUser(id: 9_001, login: "octo-student")

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-link")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        app.middleware.use(SecurityHeadersMiddleware())
        app.securityConfiguration = AppSecurityConfiguration(
            publicBaseURL: URL(string: "https://courses.example.edu"), enforceHTTPS: false,
            trustForwardedProto: true, sessionCookieSecure: false,
            sessionIdleTimeoutSeconds: 30 * 60, sessionIdleWarningSeconds: 120)
        useGitHub(user: Self.githubUser)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Points the app at a fake GitHub that returns `user` for any code.
    private func useGitHub(user: GitHubUser, exchangeFails: Bool = false) {
        let exchanged = exchanged
        let revoked = revoked
        app.githubOAuthClient = GitHubOAuthClient(
            exchangeCode: { exchange in
                exchanged.withLockedValue { $0.append(exchange) }
                if exchangeFails { throw GitHubLinkError.exchangeFailed }
                return "token-for-\(exchange.code)"
            },
            fetchUser: { _ in user },
            revokeToken: { token, _, _ in revoked.withLockedValue { $0.append(token) } })
    }

    private func registerApp(on app: Application) async throws {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "client-secret", webhookSecret: nil, pem: "pem",
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: "pem", clientSecret: "client-secret", webhookSecret: nil)
            .write(path: app.githubAppSecretsFilePath)
    }

    private func login(_ username: String = "gh_student") async throws -> String {
        try await loginUser(username: username, password: "testpassword", role: "user", on: app)
    }

    private func userID(_ username: String) async throws -> UUID {
        try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first()?.id)
    }

    @discardableResult
    private func get(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void = { _ in }
    ) async throws -> String {
        let res = try await getResponse(path, cookie: cookie, on: app)
        try check(res)
        return res.headers.first(name: .setCookie) ?? cookie
    }

    /// POSTs with a CSRF token bound to the session; returns the cookie to use next.
    @discardableResult
    private func post(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws -> String {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var next = bound
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                if let set = res.headers.first(name: .setCookie) { next = set }
                try check(res)
            })
        return next
    }

    /// Starts a link and returns the `state` sent to GitHub and the cookie.
    private func startLink(cookie: String) async throws -> (state: String, cookie: String) {
        var location = ""
        let next = try await post("/account/github/link", cookie: cookie) { res in
            #expect(res.status == .seeOther)
            location = res.headers.first(name: .location) ?? ""
        }
        let items = URLComponents(string: location)?.queryItems ?? []
        let state = try #require(items.first { $0.name == "state" }?.value)
        return (state, next)
    }

    private func links() async throws -> [APIGitHubAccountLink] {
        try await APIGitHubAccountLink.query(on: app.db).all()
    }

    @Test func withNoAppTheAccountPageHasNoGitHubSection() async throws {
        try await withApp(app) { _ in
            let cookie = try await login()
            try await get("/account", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("<h2>GitHub</h2>"))
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(!csp.contains("https://github.com"))
            }
        }
    }

    @Test func withAnAppButNoBaseURLStudentsSeeNoSection() async throws {
        app.securityConfiguration = .default
        try await withApp(app) { app in
            try await registerApp(on: app)
            let cookie = try await login()
            try await get("/account", cookie: cookie) { res in
                #expect(!res.body.string.contains("<h2>GitHub</h2>"))
            }
        }
    }

    @Test func withNoAppStartingALinkIsRefused() async throws {
        try await withApp(app) { _ in
            let cookie = try await login()
            try await post("/account/github/link", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=unavailable")
            }
        }
    }

    @Test func accountPageOffersTheLinkAndAllowsTheRedirect() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let cookie = try await login()
            try await get("/account", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("<h2>GitHub</h2>"))
                #expect(body.contains("action=\"/account/github/link\""))
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(csp.contains("form-action 'self' https://github.com"))
            }
        }
    }

    @Test func startingALinkRedirectsToGitHubWithTheAppClientID() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let cookie = try await login()
            try await post("/account/github/link", cookie: cookie) { res in
                let location = res.headers.first(name: .location) ?? ""
                #expect(location.hasPrefix("https://github.com/login/oauth/authorize?"))
                #expect(location.contains("client_id=Iv1.client"))
                #expect(location.contains("code_challenge_method=S256"))
            }
        }
    }

    @Test func callbackLinksTheAccountRevokesTheTokenAndAuditsIt() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let (state, cookie) = try await startLink(cookie: try await login())
            try await get("/github/link/callback?code=abc123&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?github=linked")
            }
            let stored = try #require(try await links().first)
            #expect(stored.userID == (try await userID("gh_student")))
            #expect(stored.githubUserID == 9_001)
            #expect(stored.githubLogin == "octo-student")

            let exchange = try #require(exchanged.withLockedValue { $0 }.first)
            #expect(exchange.code == "abc123")
            #expect(exchange.clientSecret == "client-secret")
            #expect(exchange.redirectURI == "https://courses.example.edu/github/link/callback")
            #expect(!exchange.codeVerifier.isEmpty)
            #expect(revoked.withLockedValue { $0 } == ["token-for-abc123"])

            let actions = try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
            #expect(actions.contains(AuditAction.githubAccountLinked.rawValue))

            try await get("/account?github=linked", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("GitHub account linked."))
                #expect(body.contains("octo-student"))
                #expect(body.contains("action=\"/account/github/unlink\""))
                #expect(!body.contains("token-for-"))
            }
        }
    }

    @Test func callbackRefusesAForgedStateBeforeCallingGitHub() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let (_, cookie) = try await startLink(cookie: try await login())
            try await get("/github/link/callback?code=abc&state=forged", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=stateMismatch")
            }
            #expect(exchanged.withLockedValue { $0 }.isEmpty)
            #expect(try await links().isEmpty)
        }
    }

    @Test func stateWorksOnlyOnce() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let (state, cookie) = try await startLink(cookie: try await login())
            let next = try await get("/github/link/callback?code=abc&state=\(state)", cookie: cookie)
            try await get("/github/link/callback?code=abc&state=\(state)", cookie: next) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=stateMismatch")
            }
            #expect(exchanged.withLockedValue { $0 }.count == 1)
        }
    }

    @Test func declinedAuthorizationIsReportedAsCancelled() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let (state, cookie) = try await startLink(cookie: try await login())
            try await get("/github/link/callback?error=access_denied&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=cancelled")
            }
            #expect(exchanged.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func failedExchangeStoresNothing() async throws {
        useGitHub(user: Self.githubUser, exchangeFails: true)
        try await withApp(app) { app in
            try await registerApp(on: app)
            let (state, cookie) = try await startLink(cookie: try await login())
            try await get("/github/link/callback?code=abc&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=exchangeFailed")
            }
            #expect(try await links().isEmpty)
            try await get("/account?githubError=exchangeFailed", cookie: cookie) { res in
                #expect(res.body.string.contains(GitHubLinkError.exchangeFailed.message))
            }
        }
    }

    /// The token is revoked when the user read fails, not only when it
    /// succeeds (#1765): nothing is stored, and the fake saw the revoke.
    @Test func aFailedUserReadStillRevokesTheToken() async throws {
        let revoked = revoked
        app.githubOAuthClient = GitHubOAuthClient(
            exchangeCode: { exchange in "token-for-\(exchange.code)" },
            fetchUser: { _ in throw GitHubLinkError.exchangeFailed },
            revokeToken: { token, _, _ in revoked.withLockedValue { $0.append(token) } })
        try await withApp(app) { app in
            try await registerApp(on: app)
            let (state, cookie) = try await startLink(cookie: try await login())
            try await get("/github/link/callback?code=abc&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=exchangeFailed")
            }
            #expect(revoked.withLockedValue { $0 } == ["token-for-abc"])
            #expect(try await links().isEmpty)
        }
    }

    @Test func aGitHubAccountLinksToOneChickadeeAccountOnly() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            _ = try await login("gh_other")
            try await APIGitHubAccountLink(
                userID: try await userID("gh_other"), githubUserID: 9_001, githubLogin: "octo-student"
            ).save(on: app.db)

            let (state, cookie) = try await startLink(cookie: try await login())
            try await get("/github/link/callback?code=abc&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?githubError=linkedElsewhere")
            }
            let rows = try await links()
            #expect(rows.count == 1)
            #expect(rows.first?.userID == (try await userID("gh_other")))
        }
    }

    @Test func linkingAgainReplacesTheLink() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let cookie = try await login()
            try await APIGitHubAccountLink(
                userID: try await userID("gh_student"), githubUserID: 1, githubLogin: "old-login"
            ).save(on: app.db)
            let (state, next) = try await startLink(cookie: cookie)
            try await get("/github/link/callback?code=abc&state=\(state)", cookie: next)
            let rows = try await links()
            #expect(rows.count == 1)
            #expect(rows.first?.githubUserID == 9_001)
            #expect(rows.first?.githubLogin == "octo-student")
        }
    }

    @Test func unlinkDeletesTheLinkAndAuditsIt() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let cookie = try await login()
            try await APIGitHubAccountLink(
                userID: try await userID("gh_student"), githubUserID: 9_001, githubLogin: "octo-student"
            ).save(on: app.db)
            try await post("/account/github/unlink", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/account?github=unlinked")
            }
            #expect(try await links().isEmpty)
            let actions = try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
            #expect(actions.contains(AuditAction.githubAccountUnlinked.rawValue))
        }
    }

    @Test func anExistingLinkStaysVisibleAfterTheAppIsRemoved() async throws {
        try await withApp(app) { app in
            let cookie = try await login()
            try await APIGitHubAccountLink(
                userID: try await userID("gh_student"), githubUserID: 9_001, githubLogin: "octo-student"
            ).save(on: app.db)
            try await get("/account", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("octo-student"))
                #expect(body.contains("action=\"/account/github/unlink\""))
                #expect(!body.contains("action=\"/account/github/link\""))
            }
        }
    }

    @Test func unknownNoticeAndErrorKeysShowNoBanner() async throws {
        try await withApp(app) { app in
            try await registerApp(on: app)
            let cookie = try await login()
            try await get("/account?github=%3Cb%3Eforged&githubError=%3Cb%3Eforged", cookie: cookie) { res in
                #expect(!res.body.string.contains("forged"))
            }
        }
    }

    @Test func deletingAUserDeletesTheirLink() async throws {
        try await withApp(app) { app in
            _ = try await login()
            let studentID = try await userID("gh_student")
            try await APIGitHubAccountLink(
                userID: studentID, githubUserID: 9_001, githubLogin: "octo-student"
            ).save(on: app.db)
            let admin = try await loginUser(
                username: "gh_admin", password: "testpassword", role: "admin", on: app)
            let (token, bound) = try await csrfFields(for: "/admin/users", cookie: admin, on: app)
            try await app.asyncTest(
                .POST, "/admin/users/\(studentID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: bound)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await links().isEmpty)
        }
    }

    @Test func dataExportIncludesTheLinkedAccount() async throws {
        try await withApp(app) { app in
            _ = try await login()
            let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            try await APIGitHubAccountLink(
                userID: try user.requireID(), githubUserID: 9_001, githubLogin: "octo-student"
            ).save(on: app.db)
            let content = try await gatherDataExportContent(for: user, on: app.db)
            #expect(content.profile.githubAccount?.githubUserID == 9_001)
            #expect(content.profile.githubAccount?.login == "octo-student")
        }
    }

    @Test func dataExportWithoutALinkHasNoGitHubAccount() async throws {
        try await withApp(app) { app in
            _ = try await login()
            let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            let content = try await gatherDataExportContent(for: user, on: app.db)
            #expect(content.profile.githubAccount == nil)
        }
    }
}
