// Tests/APITests/LTI/AdminLTIRoutesTests.swift
//
// The admin LTI page (docs/lti-1-3.md slice 1b): registering, editing,
// enabling, disabling and deleting a platform, the refusals an admin sees as a
// sentence, the audit trail, and the admin-only gate.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminLTIRoutesTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin-lti")
    }

    static let form: [String: String] = [
        "displayName": "UW LEARN",
        "issuer": "https://learn.example.edu",
        "clientID": "client-1",
        "deploymentIDs": "deployment-1\ndeployment-2",
        "authLoginURL": "https://learn.example.edu/d2l/lti/authenticate",
        "accessTokenURL": "https://auth.example.edu/core/connect/token",
        "jwksURL": "https://learn.example.edu/d2l/.well-known/jwks",
    ]

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "lti_admin", password: "testpassword", role: "admin", on: app)
    }

    /// POSTs `fields` to `path` as the admin, with a CSRF token bound to the session.
    private func post(
        _ path: String, _ fields: [String: String], cookie: String,
        _ check: @escaping (TestingHTTPResponse) async throws -> Void
    ) async throws {
        let (token, boundCookie) = try await csrfFields(for: "/admin/lti", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: check)
    }

    private func auditActions() async throws -> [String] {
        try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
    }

    @Test func pageShowsToolConfigurationAndAnEmptyPlatformList() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin/lti", beforeRequest: { $0.headers.add(name: .cookie, value: cookie) }
            ) { res in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("class=\"admin-tabs\""))
                #expect(body.contains("/lti/login"))
                #expect(body.contains("/lti/launch"))
                #expect(body.contains("/lti/jwks"))
                #expect(body.contains("No platforms registered."))
                #expect(body.contains("aria-current=\"page\">LTI</a>"))
            }
        }
    }

    @Test func nonAdminIsForbidden() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(username: "lti_user", password: "testpassword", role: "user", on: app)
            try await app.asyncTest(
                .GET, "/admin/lti", beforeRequest: { $0.headers.add(name: .cookie, value: cookie) }
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func registeringStoresThePlatformAndAuditsIt() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=registered")
            }
            let platform = try #require(try await APILTIPlatform.query(on: app.db).first())
            #expect(platform.displayName == "UW LEARN")
            #expect(platform.deploymentIDs == ["deployment-1", "deployment-2"])
            #expect(platform.enabled)
            let actions = try await auditActions()
            #expect(actions.contains(AuditAction.ltiPlatformRegistered.rawValue))

            try await app.asyncTest(
                .GET, "/admin/lti?ok=registered", beforeRequest: { $0.headers.add(name: .cookie, value: cookie) }
            ) { res in
                #expect(res.body.string.contains("Platform registered."))
                #expect(res.body.string.contains("UW LEARN"))
            }
        }
    }

    @Test func invalidRegistrationShowsTheReasonAndKeepsWhatWasTyped() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            var fields = Self.form
            fields["jwksURL"] = "http://learn.example.edu/jwks"
            try await post("/admin/lti/platforms", fields, cookie: cookie) { res in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("Key set URL must use https."))
                #expect(body.contains("value=\"http://learn.example.edu/jwks\""))
            }
            let count = try await APILTIPlatform.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test func duplicateIssuerAndClientIDIsRefusedAsASentence() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { _ in }
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("already registered"))
            }
            let count = try await APILTIPlatform.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    @Test func editingKeepsThePlatformIdentity() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { _ in }
            let platform = try #require(try await APILTIPlatform.query(on: app.db).first())
            let id = try platform.requireID()
            var fields = Self.form
            fields["deploymentIDs"] = "deployment-3"
            try await post("/admin/lti/platforms/\(id)", fields, cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=updated")
            }
            let updated = try #require(try await APILTIPlatform.find(id, on: app.db))
            #expect(updated.deploymentIDs == ["deployment-3"])
            let actions = try await auditActions()
            #expect(actions.contains(AuditAction.ltiPlatformUpdated.rawValue))
        }
    }

    @Test func disablingAndEnablingToggleLaunchAcceptance() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { _ in }
            let id = try #require(try await APILTIPlatform.query(on: app.db).first()).requireID()

            try await post("/admin/lti/platforms/\(id)/enabled", ["enabled": "false"], cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=disabled")
            }
            let disabled = try #require(try await APILTIPlatform.find(id, on: app.db))
            #expect(!disabled.enabled)

            try await post("/admin/lti/platforms/\(id)/enabled", ["enabled": "true"], cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=enabled")
            }
            let enabled = try #require(try await APILTIPlatform.find(id, on: app.db))
            #expect(enabled.enabled)
        }
    }

    @Test func deletingRemovesThePlatformAndAuditsIt() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { _ in }
            let id = try #require(try await APILTIPlatform.query(on: app.db).first()).requireID()
            try await post("/admin/lti/platforms/\(id)/delete", [:], cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=deleted")
            }
            let count = try await APILTIPlatform.query(on: app.db).count()
            #expect(count == 0)
            let actions = try await auditActions()
            #expect(actions.contains(AuditAction.ltiPlatformDeleted.rawValue))
        }
    }

    @Test func unknownPlatformIsNotFound() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await post("/admin/lti/platforms/\(UUID())/delete", [:], cookie: cookie) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func unknownNoticeKeyShowsNoBanner() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin/lti?ok=%3Cb%3Espoof%3C%2Fb%3E",
                beforeRequest: { $0.headers.add(name: .cookie, value: cookie) }
            ) { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("spoof"))
            }
        }
    }
}
