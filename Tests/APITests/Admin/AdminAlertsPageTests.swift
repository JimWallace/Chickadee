// Tests/APITests/Admin/AdminAlertsPageTests.swift
//
// The Health Alerts admin page.

import Elementary
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class AdminAlertsPageTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin-alerts-page")
    }

    /// A bare `?ok=` or `?error=` draws no banner. The Elementary port of the
    /// admin pages fixed an empty banner here (changelog.d/elementary-batch-2.md).
    @Test func anEmptyFlashValueDrawsNoBanner() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("alerts_page_admin", on: app)
            let empty = try await getHTML("/admin/alerts?ok=&error=", cookie: cookie, on: app)
            #expect(!empty.contains("flash flash-success"))
            #expect(!empty.contains("flash flash-error"))
            let saved = try await getHTML("/admin/alerts?ok=Webhook%20saved.", cookie: cookie, on: app)
            #expect(saved.contains("Webhook saved."))
            #expect(saved.contains("flash flash-success"))
        }
    }
}
