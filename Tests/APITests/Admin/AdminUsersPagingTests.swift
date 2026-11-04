// Tests/APITests/Admin/AdminUsersPagingTests.swift
//
// The admin People tab reads one bounded page of users (#2829): the page and
// its 5-second poll never load every account. The order keeps its meaning,
// the header counts stay deployment-wide, and the unpaged JSON feed still
// returns every user.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminUsersPagingTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-users-paging")
    }

    /// Inserts `count` plain users with a fixed hash, which is cheaper than
    /// hashing a password for each one.
    private func makeUsers(_ count: Int, prefix: String) async throws {
        for index in 0..<count {
            let user = APIUser(username: "\(prefix)\(index)", passwordHash: "unused", role: "user")
            try await user.save(on: app.db)
        }
    }

    private func user(_ username: String, seen: Date?) async throws {
        let user = APIUser(username: username, passwordHash: "unused", role: "user")
        user.lastSeenAt = seen
        try await user.save(on: app.db)
    }

    @Test func thePageKeepsThePeopleOrder() async throws {
        try await withApp(app) { _ in
            let now = Date()
            try await user("order_never_b", seen: nil)
            try await user("Order_never_a", seen: nil)
            try await user("order_old", seen: now.addingTimeInterval(-3600))
            try await user("order_recent", seen: now)

            let directory = try await AdminUserDirectory.page(1, on: app.db)
            let names = directory.users.map(\.username).filter { $0.lowercased().hasPrefix("order_") }
            #expect(names == ["order_recent", "order_old", "Order_never_a", "order_never_b"])
        }
    }

    @Test func aPageIsBoundedAndClampedToThePagesThatExist() async throws {
        try await withApp(app) { _ in
            try await makeUsers(5, prefix: "clamp_")
            let total = try await APIUser.query(on: app.db).count()
            let admins = try await APIUser.query(on: app.db).filter(\.$role == "admin").count()
            let pages = (total + 1) / 2

            let first = try await AdminUserDirectory.page(1, pageSize: 2, on: app.db)
            #expect(first.users.count == 2)
            #expect(first.total == total)
            #expect(first.adminCount == admins)
            #expect(first.pageCount == pages)
            #expect(first.firstShown == 1)
            #expect(first.lastShown == 2)

            let zero = try await AdminUserDirectory.page(0, pageSize: 2, on: app.db)
            #expect(zero.page == 1)

            let past = try await AdminUserDirectory.page(99, pageSize: 2, on: app.db)
            #expect(past.page == pages)
            #expect(!past.users.isEmpty)

            // Every user appears on exactly one page.
            var seen: [String] = []
            for page in 1...pages {
                seen += try await AdminUserDirectory.page(page, pageSize: 2, on: app.db).users.map(\.username)
            }
            #expect(seen.count == total)
            #expect(Set(seen).count == total)
        }
    }

    @Test func thePageAndItsPollShowOnePageWithLinks() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("paging_admin", on: app)
            try await makeUsers(AdminUserDirectory.pageSize + 1, prefix: "bulk_")
            let total = try await APIUser.query(on: app.db).count()
            let admins = try await APIUser.query(on: app.db).filter(\.$role == "admin").count()

            let first = try await getHTML("/admin/users", cookie: cookie, on: app)
            #expect(first.contains("\(total) users · \(admins) admins"))
            #expect(first.contains("href=\"/admin/users?page=2\""))
            #expect(!first.contains(">Previous<"))
            #expect(
                first.contains(
                    "Showing 1–\(AdminUserDirectory.pageSize) of \(total). Sort and filter apply to this page."))
            #expect(first.contains("/admin/users-data?fragment=rows&amp;page=1"))

            let second = try await getHTML("/admin/users?page=2", cookie: cookie, on: app)
            #expect(second.contains("href=\"/admin/users?page=1\""))
            #expect(second.contains("/admin/users-data?fragment=rows&amp;page=2"))
            #expect(second.contains("No users on this page match this filter."))

            let rows = try await getHTML("/admin/users-data?fragment=rows", cookie: cookie, on: app)
            #expect(rows.components(separatedBy: "<tr").count - 1 == AdminUserDirectory.pageSize)

            let paged = try await getResponse("/admin/users-data?page=2", cookie: cookie, on: app)
            let pagedRows = try paged.content.decode([AdminUserRow].self)
            #expect(pagedRows.count == total - AdminUserDirectory.pageSize)
        }
    }

    @Test func theUnpagedJSONFeedStillReturnsEveryUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("json_admin", on: app)
            try await makeUsers(AdminUserDirectory.pageSize + 1, prefix: "json_bulk_")
            let total = try await APIUser.query(on: app.db).count()

            let response = try await getResponse("/admin/users-data", cookie: cookie, on: app)
            #expect(response.status == .ok)
            let rows = try response.content.decode([AdminUserRow].self)
            #expect(rows.count == total)
        }
    }
}

/// The pager view alone: no app, so no Vapor lifecycle to shut down.
@Suite struct AdminUsersPagerTests {
    @Test func onePageRendersNoLinks() {
        let pager = AdminUsersPager(page: 1, pageCount: 1, firstShown: 1, lastShown: 3, total: 3)
        #expect(pager.render().isEmpty)
        #expect(pager.pollURL == "/admin/users-data?fragment=rows&page=1")
    }
}
