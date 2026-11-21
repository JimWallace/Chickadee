// Tests/APITests/Admin/AdminIntegrationsPagesTests.swift
//
// The admin LEARN and GitHub Integrations pages when nothing is
// configured: each shows its notice and none of its controls.

import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminIntegrationsPagesTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-integrations")
    }

    private func get(_ path: String) async throws -> String {
        let cookie = try await loginAsAdmin("integrations_admin", on: app)
        return try await getHTML(path, cookie: cookie, on: app)
    }

    @Test func learnWithoutCredentialsShowsOnlyTheNotice() async throws {
        try await withApp(app) { _ in
            let html = try await get("/admin/brightspace")
            #expect(html.contains("<p class=\"page-crumb\">Integrations</p>"))
            #expect(html.contains("<strong>Not configured.</strong>"))
            #expect(html.contains("BRIGHTSPACE_APP_KEY"))
            #expect(!html.contains("Set the user key"))
            #expect(!html.contains("name=\"userKey\""))
            #expect(html.contains("This page only sets the shared connection.") == false)
        }
    }

    @Test func githubWithoutAnAppShowsTheNotRegisteredPill() async throws {
        try await withApp(app) { _ in
            let html = try await get("/admin/github")
            #expect(html.contains("tier-closed\">Not registered<"))
            #expect(html.contains("No GitHub App registered."))
            #expect(!html.contains("Remove registration"))
        }
    }
}
