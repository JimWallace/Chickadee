// Tests/APITests/AdminBrightSpaceCredentialRoutesTests.swift
//
// The admin routes that change the deployment-wide BrightSpace credential, and
// the alert-webhook test button. Each one changes what the whole deployment
// does, so each is pinned twice: what an admin's request does, and that a
// non-admin's request changes nothing.
//
// The verified paths (a pasted key that D2L accepts, a dispatched webhook)
// call out to the network and are not exercised here.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AdminBrightSpaceCredentialRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-bs")
    }

    private static let appCredentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.test", appID: "app-id", appKey: "app-key", debounceSecs: 90)

    /// Posts `fields` to `path` as the session `cookie` and returns the
    /// response status and redirect target.
    private func post(
        _ path: String, fields: [String: String] = [:], cookie: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    private func storeGlobalCredential() async throws {
        try await BrightSpaceCredentialStore.save(
            valenceUserID: "stored-user", valenceUserKey: "stored-key",
            identityName: "Grade Sync (sync)", capturedByUserID: nil, on: app.db)
    }

    // MARK: - Authorize

    @Test func authorizeWithoutBrightSpaceConfiguredStaysOnThePage() async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = nil
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post("/admin/brightspace/authorize", cookie: cookie)

            #expect(response.location == "/admin/brightspace")
        }
    }

    @Test func authorizeWithoutAPublicBaseURLStaysOnThePage() async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = Self.appCredentials
            app.securityConfiguration = AppSecurityConfiguration(
                publicBaseURL: nil, enforceHTTPS: false, trustForwardedProto: false,
                sessionCookieSecure: false, sessionIdleTimeoutSeconds: 1_800, sessionIdleWarningSeconds: 120)
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post("/admin/brightspace/authorize", cookie: cookie)

            #expect(response.location == "/admin/brightspace")
        }
    }

    @Test func authorizeSendsTheAdminToTheLMSWithThisServersCallback() async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = Self.appCredentials
            app.securityConfiguration = AppSecurityConfiguration(
                publicBaseURL: URL(string: "https://courses.example.edu/"), enforceHTTPS: false,
                trustForwardedProto: false, sessionCookieSecure: false,
                sessionIdleTimeoutSeconds: 1_800, sessionIdleWarningSeconds: 120)
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post("/admin/brightspace/authorize", cookie: cookie)

            let location = try #require(response.location)
            #expect(location.hasPrefix("https://learn.test/d2l/auth/api/token?"))
            let target = URLComponents(string: location)?.queryItems?.first { $0.name == "x_target" }?.value
            #expect(target == "https://courses.example.edu/admin/brightspace/valence-callback")
        }
    }

    // MARK: - Clear

    @Test func clearRemovesTheStoredCredentialAndStopsTheLiveClient() async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = Self.appCredentials
            try await storeGlobalCredential()
            let config = BrightSpaceSyncConfig(app: Self.appCredentials, userID: "stored-user", userKey: "stored-key")
            app.brightSpaceSyncConfig = config
            app.brightSpaceClient = BrightSpaceAPIClient(config: config)
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post("/admin/brightspace/clear", cookie: cookie)

            #expect(response.location == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
            #expect(app.brightSpaceSyncConfig == nil, "with no env key, grade sync is disabled")
            #expect(app.brightSpaceClient == nil)
        }
    }

    // MARK: - Set credentials

    @Test(arguments: [("", "key"), ("user", ""), ("   ", "\n")])
    func setCredentialsRefusesABlankField(userID: String, userKey: String) async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = Self.appCredentials
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post(
                "/admin/brightspace/set-credentials", fields: ["userID": userID, "userKey": userKey], cookie: cookie)

            #expect(response.location == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
        }
    }

    @Test func setCredentialsWithoutBrightSpaceConfiguredStoresNothing() async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = nil
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post(
                "/admin/brightspace/set-credentials", fields: ["userID": "u", "userKey": "k"], cookie: cookie)

            #expect(response.location == "/admin/brightspace")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) == nil)
        }
    }

    // MARK: - Test alert

    @Test func aTestAlertWithNoWebhookRedirectsWithAnError() async throws {
        try await withApp(app) { _ in
            await app.serverHealthAlertMonitor.setWebhookURL("")
            let cookie = try await loginAsAdmin("bs_admin", on: app)

            let response = try await post("/admin/alerts/test", cookie: cookie)

            let location = try #require(response.location)
            #expect(location.hasPrefix("/admin/alerts?error="))
        }
    }

    // MARK: - Non-admins change nothing

    @Test(arguments: [
        "/admin/brightspace/authorize",
        "/admin/brightspace/clear",
        "/admin/brightspace/set-credentials",
        "/admin/alerts/test",
    ])
    func aNonAdminIsRefusedAndChangesNothing(path: String) async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = Self.appCredentials
            try await storeGlobalCredential()
            let cookie = try await loginAsStudent("not_admin", on: app)

            let response = try await post(path, fields: ["userID": "evil", "userKey": "evil"], cookie: cookie)

            #expect(response.status == .forbidden)
            let stored = try #require(try await BrightSpaceCredentialStore.loadGlobal(on: app.db))
            #expect(stored.valenceUserID == "stored-user")
        }
    }
}
