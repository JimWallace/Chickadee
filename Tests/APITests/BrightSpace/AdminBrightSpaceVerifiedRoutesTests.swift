// Tests/APITests/BrightSpace/AdminBrightSpaceVerifiedRoutesTests.swift
//
// The admin LEARN routes that ask D2L, against a scripted D2L: the Valence
// callback, a pasted key that whoami accepts or refuses, and the connection
// test. Also the page's key-source line and the clear route's revert to an
// environment key. `AdminBrightSpaceCredentialRoutesTests` covers the paths
// that need no D2L and the non-admin refusals.

import Core
import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AdminBrightSpaceVerifiedRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-bs-verified")
        // The test app does not install the production middleware stack; the
        // page's form-action allowance is asserted on a real header.
        app.middleware.use(SecurityHeadersMiddleware())
        // The page adds the LMS origin to `form-action`; this middleware renders it.
        app.middleware.use(SecurityHeadersMiddleware())
    }

    private static let appCredentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.test:8443", appID: "app-id", appKey: "app-key", debounceSecs: 90)

    private static let whoamiBody =
        #"{"Identifier":"42","FirstName":"Grade","LastName":"Sync","UniqueName":"gsync"}"#

    /// Configures the app credentials and a public base URL, and answers
    /// whoami with `status` (and `whoamiBody` when OK). Every other request
    /// gets 404, so version discovery falls back.
    private func configure(whoami status: HTTPResponseStatus = .ok) {
        app.brightSpaceAppCredentials = Self.appCredentials
        app.securityConfiguration = AppSecurityConfiguration(
            publicBaseURL: URL(string: "https://courses.example.edu"), enforceHTTPS: false,
            trustForwardedProto: false, sessionCookieSecure: false,
            sessionIdleTimeoutSeconds: 1_800, sessionIdleWarningSeconds: 120)
        _ = app.useScriptedValence { _, url, _ in
            guard url.contains("/users/whoami") else { return ScriptedValenceReply(.notFound) }
            return status == .ok ? ScriptedValenceReply(.ok, Self.whoamiBody) : ScriptedValenceReply(status, "{}")
        }
    }

    /// Posts `fields` to `path` as the session `cookie` and returns the
    /// redirect target and the cookie that carries the session.
    private func post(
        _ path: String, fields: [String: String] = [:], cookie: String
    ) async throws -> (location: String?, cookie: String) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                location = res.headers.first(name: .location)
            })
        return (location, bound)
    }

    private func callback(_ query: String, cookie: String) async throws -> TestResponse {
        try await getResponse("/admin/brightspace/valence-callback?\(query)", cookie: cookie, on: app)
    }

    private func auditMetadata(_ action: AuditAction) async throws -> [[String: String]] {
        try await APIAuditLogEntry.query(on: app.db)
            .filter(\.$action == action.rawValue)
            .all()
            .map(\.metadataDictionary)
    }

    // MARK: - Page

    @Test func aStoredKeyIsShownAsSetOnThisPageAndTheLMSOriginMayReceiveTheForm() async throws {
        try await withApp(app) { _ in
            configure()
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "stored", valenceUserKey: "k", identityName: "Grade Sync (gsync)",
                capturedByUserID: nil, on: app.db)
            app.brightSpaceClient = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: Self.appCredentials, userID: "stored", userKey: "k"))
            let cookie = try await loginAsAdmin("bsv_admin", on: app)

            let response = try await getResponse("/admin/brightspace", cookie: cookie, on: app)

            #expect(response.status == .ok)
            let html = response.body.string
            #expect(html.contains("Key set on this page"))
            #expect(html.contains("Grade Sync (gsync)"))
            #expect(html.contains("Clear authorization"))
            let csp = response.headers.first(name: "Content-Security-Policy") ?? ""
            #expect(csp.contains("https://learn.test:8443"), "form-action names the LMS origin with its port")
        }
    }

    @Test func anEnvironmentKeyIsShownAsFromTheEnvironment() async throws {
        try await withApp(app) { _ in
            configure()
            app.brightSpaceClient = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: Self.appCredentials, userID: "env", userKey: "k"))
            let cookie = try await loginAsAdmin("bsv_admin", on: app)

            let html = try await getHTML("/admin/brightspace", cookie: cookie, on: app)

            #expect(html.contains("Using key from environment"))
            #expect(!html.contains("Clear authorization"))
        }
    }

    // MARK: - Valence callback

    @Test func aCallbackWithoutAPendingAuthorizeIsRefused() async throws {
        try await withApp(app) { _ in
            configure()
            let cookie = try await loginAsAdmin("bsv_admin", on: app)

            let response = try await callback("x_a=u&x_b=k", cookie: cookie)

            #expect(response.headers.first(name: .location) == "/admin/brightspace")
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            #expect(app.brightSpaceClient == nil)
            let html = try await getHTML("/admin/brightspace", cookie: cookie, on: app)
            #expect(html.contains("originate here"))
        }
    }

    @Test(arguments: ["x_a=u", "x_b=k", "x_a=&x_b=k", ""])
    func aCallbackWithoutBothKeyHalvesStoresNothing(query: String) async throws {
        try await withApp(app) { _ in
            configure()
            let admin = try await loginAsAdmin("bsv_admin", on: app)
            let cookie = try await post("/admin/brightspace/authorize", cookie: admin).cookie

            let response = try await callback(query, cookie: cookie)

            #expect(response.headers.first(name: .location) == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            let html = try await getHTML("/admin/brightspace", cookie: cookie, on: app)
            #expect(html.contains("did not return a user key"))
        }
    }

    @Test func aCallbackAfterTheCredentialsWereRemovedStoresNothing() async throws {
        try await withApp(app) { _ in
            configure()
            let admin = try await loginAsAdmin("bsv_admin", on: app)
            let cookie = try await post("/admin/brightspace/authorize", cookie: admin).cookie
            app.brightSpaceAppCredentials = nil

            let response = try await callback("x_a=u&x_b=k", cookie: cookie)

            #expect(response.headers.first(name: .location) == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            #expect(app.brightSpaceClient == nil)
        }
    }

    @Test func aCallbackWhoseKeyD2LRefusesStoresNothing() async throws {
        try await withApp(app) { _ in
            configure(whoami: .forbidden)
            let admin = try await loginAsAdmin("bsv_admin", on: app)
            let cookie = try await post("/admin/brightspace/authorize", cookie: admin).cookie

            let response = try await callback("x_a=u&x_b=k", cookie: cookie)

            #expect(response.headers.first(name: .location) == "/admin/brightspace")
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            #expect(app.brightSpaceClient == nil)
            let html = try await getHTML("/admin/brightspace", cookie: cookie, on: app)
            #expect(html.contains("could not be verified"))
        }
    }

    @Test func aVerifiedCallbackStoresTheKeyRebuildsTheClientAndIsSingleUse() async throws {
        try await withApp(app) { _ in
            configure()
            let admin = try await loginAsAdmin("bsv_admin", on: app)
            let cookie = try await post("/admin/brightspace/authorize", cookie: admin).cookie

            let response = try await callback("x_a=captured-user&x_b=captured-key", cookie: cookie)

            #expect(response.headers.first(name: .location) == "/admin/brightspace")
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            let stored = try #require(try await BrightSpaceCredentialStore.loadGlobal(on: app.db))
            #expect(stored.valenceUserID == "captured-user")
            #expect(stored.identityName == "Grade Sync (gsync)")
            #expect(app.brightSpaceSyncConfig?.userID == "captured-user")
            #expect(app.brightSpaceClient != nil)
            let audits = try await auditMetadata(.brightspaceAdminAuthorized)
            #expect(audits.count == 1)
            #expect(audits.first?["source"] == "valence_callback")
            #expect(audits.first?["identity"] == "Grade Sync (gsync)")
            let html = try await getHTML("/admin/brightspace", cookie: cookie, on: app)
            #expect(html.contains("BrightSpace authorized as Grade Sync (gsync)."))

            // The pending marker is spent: a replay of the same callback is refused.
            _ = try await callback("x_a=other-user&x_b=other-key", cookie: cookie)
            let after = try #require(try await BrightSpaceCredentialStore.loadGlobal(on: app.db))
            #expect(after.valenceUserID == "captured-user")
        }
    }

    // MARK: - Set credentials

    @Test func aPastedKeyThatD2LAcceptsIsStoredAndGoesLive() async throws {
        try await withApp(app) { _ in
            configure()
            let admin = try await loginAsAdmin("bsv_admin", on: app)

            let result = try await post(
                "/admin/brightspace/set-credentials",
                fields: ["userID": "  pasted-user\n", "userKey": " pasted-key "], cookie: admin)

            #expect(result.location == "/admin/brightspace")
            let stored = try #require(try await BrightSpaceCredentialStore.loadGlobal(on: app.db))
            #expect(stored.valenceUserID == "pasted-user", "the pasted values are trimmed")
            #expect(stored.identityName == "Grade Sync (gsync)")
            #expect(app.brightSpaceSyncConfig?.userKey == "pasted-key")
            #expect(app.brightSpaceSyncConfig?.userID == "pasted-user")
            #expect(app.brightSpaceClient != nil)
            let audits = try await auditMetadata(.brightspaceAdminAuthorized)
            #expect(audits.first?["source"] == "manual")
            let html = try await getHTML("/admin/brightspace", cookie: result.cookie, on: app)
            #expect(html.contains("connected as Grade Sync (gsync)."))
        }
    }

    @Test func aPastedKeyThatD2LRefusesIsNotStored() async throws {
        try await withApp(app) { _ in
            configure(whoami: .unauthorized)
            let admin = try await loginAsAdmin("bsv_admin", on: app)

            let result = try await post(
                "/admin/brightspace/set-credentials", fields: ["userID": "u", "userKey": "bad"], cookie: admin)

            #expect(result.location == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            #expect(app.brightSpaceClient == nil)
            #expect(try await auditMetadata(.brightspaceAdminAuthorized).isEmpty)
            let html = try await getHTML("/admin/brightspace", cookie: result.cookie, on: app)
            #expect(html.contains("verify those credentials"))
        }
    }

    // MARK: - Test connection

    @Test func testingWithNoClientSaysThereIsNothingToTest() async throws {
        try await withApp(app) { _ in
            configure()
            let admin = try await loginAsAdmin("bsv_admin", on: app)

            let result = try await post("/admin/brightspace/test", cookie: admin)

            #expect(result.location == "/admin/brightspace")
            let html = try await getHTML("/admin/brightspace", cookie: result.cookie, on: app)
            #expect(html.contains("nothing to test"))
        }
    }

    @Test(arguments: [
        (HTTPResponseStatus.ok, "Connected as Grade Sync (gsync)."),
        (HTTPResponseStatus.forbidden, "connect to LEARN"),
    ])
    func testingReportsWhatWhoamiSaid(status: HTTPResponseStatus, flash: String) async throws {
        try await withApp(app) { _ in
            configure(whoami: status)
            let live = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: Self.appCredentials, userID: "live", userKey: "k"))
            app.brightSpaceClient = live
            let admin = try await loginAsAdmin("bsv_admin", on: app)

            let result = try await post("/admin/brightspace/test", cookie: admin)

            #expect(result.location == "/admin/brightspace")
            let html = try await getHTML("/admin/brightspace", cookie: result.cookie, on: app)
            #expect(html.contains(flash))
            #expect(app.brightSpaceClient === live, "a test changes nothing")
        }
    }

    // MARK: - Clear

    @Test func clearingRevertsToTheEnvironmentKeyWhenThereIsOne() async throws {
        try await withApp(app) { _ in
            configure()
            let envConfig = BrightSpaceSyncConfig(app: Self.appCredentials, userID: "env-user", userKey: "env-key")
            let base = app.appConfig
            app.appConfig = AppConfig(
                auth: base.auth, oidc: base.oidc, security: base.security, scanMode: base.scanMode,
                database: base.database, lockout: base.lockout, workers: base.workers,
                brightspace: envConfig, brightspaceApp: Self.appCredentials,
                diagnostics: base.diagnostics, alerts: base.alerts, outboundProxy: base.outboundProxy,
                mcp: base.mcp, uwDates: base.uwDates)
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "stored", valenceUserKey: "k", identityName: "Grade Sync",
                capturedByUserID: nil, on: app.db)
            app.brightSpaceClient = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: Self.appCredentials, userID: "stored", userKey: "k"))
            let admin = try await loginAsAdmin("bsv_admin", on: app)

            let result = try await post("/admin/brightspace/clear", cookie: admin)

            #expect(result.location == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            #expect(app.brightSpaceSyncConfig?.userID == "env-user")
            #expect(app.brightSpaceClient != nil)
            let audits = try await auditMetadata(.brightspaceAdminCleared)
            #expect(audits.first?["reverted_to"] == "env")
        }
    }
}
