// Tests/APITests/Admin/AdminUserRowDisplayNameTests.swift
//
// One row of the admin users list.

import Elementary
import Testing

@testable import APIServer

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
