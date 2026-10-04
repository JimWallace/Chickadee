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

    /// POSTs `fields` to `path` as the admin, with a CSRF token bound to the session.
    private func post(
        _ path: String, _ fields: [String: String], cookie: String,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
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

    /// GETs `path` with the session cookie.
    private func get(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: check)
    }

    private func auditActions() async throws -> [String] {
        try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
    }

    @Test func pageShowsToolConfigurationAndAnEmptyPlatformList() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
            try await get("/admin/lti", cookie: cookie) { res in
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
            try await get("/admin/lti", cookie: cookie) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func registeringStoresThePlatformAndAuditsIt() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
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

            try await get("/admin/lti?ok=registered", cookie: cookie) { res in
                #expect(res.body.string.contains("Platform registered."))
                #expect(res.body.string.contains("UW LEARN"))
            }
        }
    }

    @Test func invalidRegistrationShowsTheReasonAndKeepsWhatWasTyped() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
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
            let cookie = try await loginAsAdmin("lti_admin", on: app)
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
            let cookie = try await loginAsAdmin("lti_admin", on: app)
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

    @Test func tokenAudienceIsStoredShownForEditingAndClearedWhenBlank() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
            var fields = Self.form
            fields["tokenAudience"] = " https://api.brightspace.com/auth/token "
            try await post("/admin/lti/platforms", fields, cookie: cookie) { _ in }
            let platform = try #require(try await APILTIPlatform.query(on: app.db).first())
            let id = try platform.requireID()
            #expect(platform.tokenAudience == "https://api.brightspace.com/auth/token")

            try await get("/admin/lti", cookie: cookie) { res in
                #expect(res.body.string.contains("value=\"https://api.brightspace.com/auth/token\""))
            }

            fields["tokenAudience"] = ""
            try await post("/admin/lti/platforms/\(id)", fields, cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=updated")
            }
            let updated = try #require(try await APILTIPlatform.find(id, on: app.db))
            #expect(updated.tokenAudience == nil)
            try await get("/admin/lti", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("api.brightspace.com"))
            }
        }
    }

    @Test func disablingAndEnablingToggleLaunchAcceptance() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
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
            let cookie = try await loginAsAdmin("lti_admin", on: app)
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
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
            try await post("/admin/lti/platforms/\(UUID())/delete", [:], cookie: cookie) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func unknownNoticeKeyShowsNoBanner() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
            try await get("/admin/lti?ok=%3Cb%3Espoof%3C%2Fb%3E", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("spoof"))
            }
        }
    }

    @Test func deletingUnbindsItsCoursesSoGradesStopGoingThroughAGS() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_admin", on: app)
            try await post("/admin/lti/platforms", Self.form, cookie: cookie) { _ in }
            let platformID = try #require(try await APILTIPlatform.query(on: app.db).first()).requireID()
            let courseID = try await app.testCourseID(code: "LTI-BOUND")
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.ltiPlatformID = platformID
            course.ltiContextID = "ctx-1"
            course.ltiLineItemsURL = "https://learn.example.edu/lineitems"
            course.ltiMembershipsURL = "https://learn.example.edu/members"
            course.ltiGradesEnabled = true
            try await course.save(on: app.db)

            try await post("/admin/lti/platforms/\(platformID)/delete", [:], cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/admin/lti?ok=deletedUnbound")
            }
            let after = try #require(try await APICourse.find(courseID, on: app.db))
            #expect(after.ltiPlatformID == nil)
            #expect(after.ltiContextID == nil)
            #expect(after.ltiLineItemsURL == nil)
            #expect(after.ltiMembershipsURL == nil)
            #expect(after.usesLTIGrades == false)
            let count = try await APILTIPlatform.query(on: app.db).count()
            #expect(count == 0)
        }
    }
}
