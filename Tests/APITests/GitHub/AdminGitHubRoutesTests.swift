// Tests/APITests/GitHub/AdminGitHubRoutesTests.swift
//
// The admin GitHub page (docs/github-submissions.md slice 1): the manifest form
// and its CSP allowance, the callback that exchanges the code, every refusal an
// admin sees as a sentence, removal, the audit trail and the admin-only gate.
// The manifest conversion is faked, so no test reaches GitHub.

import ChickadeeTestSupport
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminGitHubRoutesTests {
    let app: Application
    let directory: URL
    var secretsPath: String { directory.appendingPathComponent(".github-app-secrets").path }

    static let conversion = GitHubManifestConversion(
        id: 4242, slug: "chickadee-courses", name: "Chickadee (courses.example.edu)",
        clientID: "Iv1.client", clientSecret: "client-secret", webhookSecret: nil,
        pem: "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----\n",
        htmlURL: "https://github.com/apps/chickadee-courses",
        owner: .init(login: "uwaterloo-cs"))

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin-github")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-admin-github-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        // The test app does not install the production middleware stack; the
        // manifest form's form-action allowance is asserted on a real header.
        app.middleware.use(SecurityHeadersMiddleware())
        app.githubManifestConverter = { _ in throw IssueRecorded("the converter was not expected to run") }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func setPublicBaseURL(_ url: String) {
        app.securityConfiguration = AppSecurityConfiguration(
            publicBaseURL: URL(string: url), enforceHTTPS: false, trustForwardedProto: true,
            sessionCookieSecure: false, sessionIdleTimeoutSeconds: 30 * 60, sessionIdleWarningSeconds: 120)
    }

    /// GETs `path` with the session cookie, and returns the cookie to use
    /// next (the response's, when it sets one).
    @discardableResult
    private func get(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void = { _ in }
    ) async throws -> String {
        var next = cookie
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                if let set = res.headers.first(name: .setCookie) { next = set }
                try check(res)
            })
        return next
    }

    /// Opens the page so the session holds a manifest `state`, and returns the
    /// state and the cookie that carries it.
    private func openManifestForm(cookie: String) async throws -> (state: String, cookie: String) {
        var html = ""
        let next = try await get("/admin/github", cookie: cookie) { res in html = res.body.string }
        let marker = "settings/apps/new?state="
        let start = try #require(html.range(of: marker)).upperBound
        let state = String(html[start...].prefix { $0 != "\"" })
        return (state, next)
    }

    private func auditActions() async throws -> [String] {
        try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
    }

    private func register(on app: Application) async throws {
        try await APIGitHubApp(conversion: Self.conversion).save(on: app.db)
    }

    @Test func withoutABaseURLThePageExplainsAndOffersNoForm() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github", cookie: cookie) { res in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("No GitHub App registered."))
                #expect(body.contains("PUBLIC_BASE_URL"))
                #expect(!body.contains("github.com/settings/apps/new"))
                #expect(body.contains("aria-current=\"page\">GitHub</a>"))
            }
        }
    }

    @Test func manifestFormPostsToGitHubAndTheCSPAllowsIt() async throws {
        setPublicBaseURL("https://courses.example.edu")
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("action=\"https://github.com/settings/apps/new?state="))
                #expect(body.contains("name=\"manifest\""))
                #expect(body.contains("<details id=\"github-app-options\">"))
                #expect(body.contains("https://courses.example.edu/admin/github/callback"))
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(csp.contains("form-action 'self' https://github.com"))
            }
        }
    }

    @Test func organizationMovesTheFormToTheOrganization() async throws {
        setPublicBaseURL("https://courses.example.edu")
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github?org=uwaterloo-cs", cookie: cookie) { res in
                let body = res.body.string
                #expect(
                    body.contains("action=\"https://github.com/organizations/uwaterloo-cs/settings/apps/new?state="))
                #expect(body.contains("the organization uwaterloo-cs"))
                #expect(body.contains("<details id=\"github-app-options\" open>"))
            }
        }
    }

    @Test func invalidOrganizationIsRefusedAsASentence() async throws {
        setPublicBaseURL("https://courses.example.edu")
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github?org=not%2Fan%2Forg", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains(GitHubAppRegistrationError.invalidOrganization.message))
                #expect(!body.contains("settings/apps/new"))
            }
        }
    }

    @Test func nonAdminIsForbidden() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "github_user", password: "testpassword", role: "user", on: app)
            try await get("/admin/github", cookie: cookie) { res in #expect(res.status == .forbidden) }
            try await get("/admin/github/callback?code=abc&state=x", cookie: cookie) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func callbackStoresTheAppAndItsSecretsAndAuditsIt() async throws {
        setPublicBaseURL("https://courses.example.edu")
        let requested = NIOLockedValueBox<[String]>([])
        app.githubManifestConverter = { code in
            requested.withLockedValue { $0.append(code) }
            return Self.conversion
        }
        try await withApp(app) { app in
            let login = try await loginAsAdmin("github_admin", on: app)
            let (state, cookie) = try await openManifestForm(cookie: login)
            try await get("/admin/github/callback?code=the-code&state=\(state)", cookie: cookie) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/admin/github?ok=registered")
            }
            #expect(requested.withLockedValue { $0 } == ["the-code"])

            let stored = try #require(try await APIGitHubApp.query(on: app.db).first())
            #expect(stored.appID == 4242)
            #expect(stored.clientID == "Iv1.client")
            #expect(stored.ownerLogin == "uwaterloo-cs")
            #expect(try GitHubAppSecrets.load(path: secretsPath) == Self.conversion.secrets)
            let mode = try FileManager.default.attributesOfItem(atPath: secretsPath)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(try await auditActions().contains(AuditAction.githubAppRegistered.rawValue))

            try await get("/admin/github?ok=registered", cookie: cookie) { res in
                let body = res.body.string
                #expect(body.contains("GitHub App registered."))
                #expect(body.contains("4242"))
                #expect(body.contains("https://github.com/apps/chickadee-courses"))
                #expect(!body.contains("settings/apps/new"))
                #expect(!body.contains("client-secret"))
            }
        }
    }

    @Test func callbackRefusesAStateThisSessionDidNotSend() async throws {
        setPublicBaseURL("https://courses.example.edu")
        try await withApp(app) { app in
            let login = try await loginAsAdmin("github_admin", on: app)
            let (_, cookie) = try await openManifestForm(cookie: login)
            try await get("/admin/github/callback?code=abc&state=forged", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=stateMismatch")
            }
            #expect(try await APIGitHubApp.query(on: app.db).count() == 0)
            #expect(!FileManager.default.fileExists(atPath: secretsPath))
        }
    }

    @Test func callbackWithoutAnOpenedFormIsRefused() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github/callback?code=abc&state=anything", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=stateMismatch")
            }
        }
    }

    @Test func stateWorksOnlyOnce() async throws {
        setPublicBaseURL("https://courses.example.edu")
        app.githubManifestConverter = { _ in throw GitHubAppRegistrationError.conversionFailed }
        try await withApp(app) { _ in
            let login = try await loginAsAdmin("github_admin", on: app)
            let (state, cookie) = try await openManifestForm(cookie: login)
            try await get("/admin/github/callback?code=abc&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=conversionFailed")
            }
            try await get("/admin/github/callback?code=abc&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=stateMismatch")
            }
        }
    }

    @Test func malformedCodeIsRefusedBeforeAnyRequest() async throws {
        setPublicBaseURL("https://courses.example.edu")
        try await withApp(app) { _ in
            let login = try await loginAsAdmin("github_admin", on: app)
            let (state, cookie) = try await openManifestForm(cookie: login)
            try await get("/admin/github/callback?code=..%2Fx&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=missingCode")
            }
        }
    }

    @Test func failedConversionStoresNothing() async throws {
        setPublicBaseURL("https://courses.example.edu")
        app.githubManifestConverter = { _ in throw GitHubAppRegistrationError.conversionFailed }
        try await withApp(app) { app in
            let login = try await loginAsAdmin("github_admin", on: app)
            let (state, cookie) = try await openManifestForm(cookie: login)
            try await get("/admin/github/callback?code=abc&state=\(state)", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=conversionFailed")
            }
            #expect(try await APIGitHubApp.query(on: app.db).count() == 0)
            #expect(!FileManager.default.fileExists(atPath: secretsPath))
            try await get("/admin/github?error=conversionFailed", cookie: cookie) { res in
                #expect(res.body.string.contains(GitHubAppRegistrationError.conversionFailed.message))
            }
        }
    }

    @Test func secondRegistrationIsRefused() async throws {
        try await withApp(app) { app in
            try await register(on: app)
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github/callback?code=abc&state=x", cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/github?error=alreadyRegistered")
            }
            #expect(try await APIGitHubApp.query(on: app.db).count() == 1)
        }
    }

    @Test func removingDeletesTheRowAndTheSecretsAndAuditsIt() async throws {
        try await withApp(app) { app in
            try await register(on: app)
            try Self.conversion.secrets.write(path: secretsPath)
            let cookie = try await loginAsAdmin("github_admin", on: app)
            let (token, boundCookie) = try await csrfFields(for: "/admin/github", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/github/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/github?ok=removed")
                })
            #expect(try await APIGitHubApp.query(on: app.db).count() == 0)
            #expect(!FileManager.default.fileExists(atPath: secretsPath))
            #expect(try await auditActions().contains(AuditAction.githubAppRemoved.rawValue))
        }
    }

    /// The cached installation tokens belong to the removed App, so removal
    /// drops them; the next App does not inherit them (#2209).
    @Test func removingClearsTheInstallationTokenCache() async throws {
        try await withApp(app) { app in
            try await register(on: app)
            try Self.conversion.secrets.write(path: secretsPath)
            for account: Int64 in [11, 12] {
                await app.githubInstallationTokens.store(
                    GitHubInstallationToken(token: "old-\(account)", expiresAt: Date().addingTimeInterval(3_600)),
                    forAccount: account)
            }
            let cookie = try await loginAsAdmin("github_admin", on: app)
            let (token, boundCookie) = try await csrfFields(for: "/admin/github", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/github/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(await app.githubInstallationTokens.count == 0)
            #expect(await app.githubInstallationTokens.token(forAccount: 11) == nil)
        }
    }

    @Test func removingWithNoAppIsNotFound() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            let (token, boundCookie) = try await csrfFields(for: "/admin/github", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/github/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    @Test func unknownNoticeAndErrorKeysShowNoBanner() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("github_admin", on: app)
            try await get("/admin/github?ok=%3Cscript%3E&error=%3Cb%3Eforged", cookie: cookie) { res in
                let body = res.body.string
                #expect(!body.contains("<script>"))
                #expect(!body.contains("forged"))
                #expect(!body.contains("flash-success"))
            }
        }
    }
}
