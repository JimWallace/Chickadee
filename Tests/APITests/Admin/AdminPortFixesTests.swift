import Elementary
import Testing
import VaporTesting

@testable import APIServer

/// The empty-flash fix the Elementary port of the admin pages made
/// (changelog.d/elementary-batch-2.md).
@Suite(.serialized, .timeLimit(.minutes(2))) final class AdminPortFixesTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin-port-fixes")
    }

    /// A bare `?ok=` or `?error=` draws no banner on Health Alerts.
    @Test func anEmptyFlashValueDrawsNoBanner() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("port_fixes_admin", on: app)
            let empty = try await getHTML("/admin/alerts?ok=&error=", cookie: cookie, on: app)
            #expect(!empty.contains("flash flash-success"))
            #expect(!empty.contains("flash flash-error"))
            let saved = try await getHTML("/admin/alerts?ok=Webhook%20saved.", cookie: cookie, on: app)
            #expect(saved.contains("Webhook saved."))
            #expect(saved.contains("flash flash-success"))
        }
    }
}

/// The empty display name fix from the same port.
@Suite struct AdminUserRowDisplayNameTests {
    /// An account with an empty display name shows and sorts by its username.
    @Test func anEmptyDisplayNameFallsBackToTheUsername() {
        let row = AdminUserRow(
            id: "u1", displayName: "", username: "ada", role: "user", createdAt: "2026-10-01", lastSeenAt: nil)
        let html = UserRow(user: row, csrfToken: "t").render()
        #expect(html.contains(#"data-sort-value="ada""#))
        #expect(html.contains(#"<div class="item-title"><code>ada</code></div>"#))
        #expect(!html.contains(#"<div class="item-title"></div>"#))
    }
}
