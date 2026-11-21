// Tests/APITests/LTI/AdminLTIPageTests.swift
//
// The admin LTI page in the shared Integrations row shape: the copy
// buttons, the enabled select that saves on change, the edit panel
// reopening on a validation error, and the delete confirmation.

import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminLTIPageTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-lti-page")
    }

    private static let form: [String: String] = [
        "displayName": "UW LEARN", "issuer": "https://learn.example.edu", "clientID": "client-1",
        "deploymentIDs": "deployment-1\ndeployment-2",
        "authLoginURL": "https://learn.example.edu/d2l/lti/authenticate",
        "accessTokenURL": "https://auth.example.edu/core/connect/token",
        "jwksURL": "https://learn.example.edu/d2l/.well-known/jwks",
    ]

    private func post(_ path: String, _ fields: [String: String], cookie: String) async throws -> String {
        let (token, boundCookie) = try await csrfFields(for: "/admin/lti", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        var html = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in html = res.body.string })
        return html
    }

    @Test func everyToolURLHasACopyButton() async throws {
        try await withApp(app) { _ in
            let html = try await getHTML(
                "/admin/lti", cookie: try await loginAsAdmin("lti_page_admin", on: app), on: app)
            #expect(html.components(separatedBy: "data-copy-url=\"").count - 1 == 4)
            #expect(html.contains("+ Register platform"))
            #expect(html.contains("0 platform(s) enabled"))
        }
    }

    @Test func aPlatformRowHasAnEnabledSelectThatSavesOnChangeAndAMutedRowWhenOff() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_page_admin", on: app)
            _ = try await post("/admin/lti/platforms", Self.form, cookie: cookie)
            let platform = try #require(try await APILTIPlatform.query(on: app.db).first())
            var html = try await getHTML("/admin/lti", cookie: cookie, on: app)
            #expect(html.contains("1 platform(s) enabled"))
            #expect(html.contains("<option value=\"true\" selected>Enabled</option>"))
            #expect(html.contains("data-ck-submit-on-change"))
            #expect(html.contains("action=\"/admin/lti/platforms/\(try platform.requireID())/enabled\""))
            #expect(!html.contains("class=\"row-muted\""))
            _ = try await post(
                "/admin/lti/platforms/\(try platform.requireID())/enabled", ["enabled": "false"],
                cookie: cookie)
            html = try await getHTML("/admin/lti", cookie: cookie, on: app)
            #expect(html.contains("<option value=\"false\" selected>Disabled</option>"))
            #expect(html.contains("class=\"row-muted\""))
        }
    }

    @Test func aFailedEditReopensItsPanel() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_page_admin", on: app)
            _ = try await post("/admin/lti/platforms", Self.form, cookie: cookie)
            let id = try #require(try await APILTIPlatform.query(on: app.db).first()).requireID()
            var bad = Self.form
            bad["jwksURL"] = "http://learn.example.edu/jwks"
            let html = try await post("/admin/lti/platforms/\(id)", bad, cookie: cookie)
            #expect(html.contains("Key set URL must use https."))
            #expect(html.contains("class=\"add-panel card is-open\" id=\"edit-platform-\(id)\""))
        }
    }

    @Test func deletingKeepsItsConfirmation() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("lti_page_admin", on: app)
            _ = try await post("/admin/lti/platforms", Self.form, cookie: cookie)
            let html = try await getHTML("/admin/lti", cookie: cookie, on: app)
            #expect(html.contains("Delete the platform UW LEARN? Launches from it stop immediately"))
            #expect(html.contains("Delete platform"))
        }
    }
}
