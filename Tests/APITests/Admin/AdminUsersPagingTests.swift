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
            #expect(first.contains("\(total) users · \(admins) \(admins == 1 ? "admin" : "admins")"))
            #expect(first.contains("href=\"/admin/users?page=2\""))
            #expect(!first.contains(">Previous<"))
            #expect(
                first.contains(
                    "Showing 1–\(AdminUserDirectory.pageSize) of \(total); press Enter to search every account."
                ))
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

    @Test func aSearchReachesEveryAccountBeforeThePageIsCut() async throws {
        try await withApp(app) { _ in
            try await makeUsers(AdminUserDirectory.pageSize + 1, prefix: "haystack_")
            try await user("Needle_Person", seen: nil)
            let total = try await APIUser.query(on: app.db).count()

            let found = try await AdminUserDirectory.page(1, search: "  needle ", on: app.db)
            #expect(found.users.map(\.username) == ["Needle_Person"])
            #expect(found.matchCount == 1)
            #expect(found.total == total)
            #expect(found.search == "needle")

            let none = try await AdminUserDirectory.page(1, search: "   ", on: app.db)
            #expect(none.search == nil)
            #expect(none.matchCount == total)
        }
    }

    @Test func aSearchMatchesDisplayNameAndRoleAndTreatsWildcardsAsText() async throws {
        try await withApp(app) { _ in
            let named = APIUser(username: "plain_zz", passwordHash: "unused", role: "user", displayName: "Quilla Marsh")
            try await named.save(on: app.db)
            try await user("wild_a_b", seen: nil)
            try await user("wild_axb", seen: nil)
            try await user("wild_100%_sure", seen: nil)
            try await user("wild_100x_sure", seen: nil)
            _ = try await makeTestUser(on: app, username: "role_search_admin", role: "admin")

            let byName = try await AdminUserDirectory.page(1, search: "quilla", on: app.db)
            #expect(byName.users.map(\.username) == ["plain_zz"])

            let underscore = try await AdminUserDirectory.page(1, search: "wild_a_", on: app.db)
            #expect(underscore.users.map(\.username) == ["wild_a_b"])

            let percent = try await AdminUserDirectory.page(1, search: "100%", on: app.db)
            #expect(percent.users.map(\.username) == ["wild_100%_sure"])

            // The role column matches too: every admin is found, and no
            // other user whose name lacks "admin".
            let admins = try await AdminUserDirectory.page(1, search: "ADMIN", on: app.db)
            let expected = try await APIUser.query(on: app.db).all()
                .filter { $0.role == "admin" || $0.username.lowercased().contains("admin") }
                .map(\.username)
            #expect(Set(admins.users.map(\.username)) == Set(expected))
            #expect(admins.users.contains { $0.username == "role_search_admin" })
            #expect(!admins.users.contains { $0.username == "plain_zz" })
        }
    }

    @Test func aSearchThatSpansPagesIsPagedAndClamped() async throws {
        try await withApp(app) { _ in
            try await makeUsers(5, prefix: "span_match_")
            try await makeUsers(3, prefix: "span_other_")

            let first = try await AdminUserDirectory.page(1, search: "span_match", pageSize: 2, on: app.db)
            #expect(first.matchCount == 5)
            #expect(first.pageCount == 3)
            #expect(first.users.count == 2)

            let past = try await AdminUserDirectory.page(9, search: "span_match", pageSize: 2, on: app.db)
            #expect(past.page == 3)
            #expect(past.users.count == 1)

            var seen: [String] = []
            for page in 1...3 {
                seen += try await AdminUserDirectory.page(page, search: "span_match", pageSize: 2, on: app.db)
                    .users.map(\.username)
            }
            #expect(Set(seen) == Set((0..<5).map { "span_match_\($0)" }))
        }
    }

    @Test func thePageSearchesOnTheServerAndCarriesTheSearch() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("search_admin", on: app)
            try await makeUsers(AdminUserDirectory.pageSize + 1, prefix: "crowd_")
            try await user("findme_person", seen: nil)
            let total = try await APIUser.query(on: app.db).count()

            let html = try await getHTML("/admin/users?q=FindMe", cookie: cookie, on: app)
            #expect(html.contains("<code>findme_person</code>"))
            #expect(!html.contains("<code>crowd_"))
            #expect(html.contains("1 user matches “FindMe”."))
            #expect(html.contains("\(total) users · "))
            #expect(html.contains("name=\"q\" value=\"FindMe\""))
            #expect(html.contains("href=\"/admin/users\">Clear<"))
            #expect(html.contains("/admin/users-data?fragment=rows&amp;page=1&amp;q=FindMe"))

            let empty = try await getHTML("/admin/users?q=nobody-here", cookie: cookie, on: app)
            #expect(empty.contains("No users match “nobody-here”."))

            let rows = try await getHTML("/admin/users-data?fragment=rows&q=findme", cookie: cookie, on: app)
            #expect(rows.contains("<code>findme_person</code>"))
            #expect(!rows.contains("<code>crowd_"))

            let json = try await getResponse("/admin/users-data?q=findme", cookie: cookie, on: app)
            let jsonRows = try json.content.decode([AdminUserRow].self)
            #expect(jsonRows.map(\.username) == ["findme_person"])
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
        let pager = AdminUsersPager(page: 1, pageCount: 1, firstShown: 1, lastShown: 3, matchCount: 3)
        #expect(pager.render().isEmpty)
        #expect(pager.pollURL == "/admin/users-data?fragment=rows&page=1")
    }

    @Test func theSearchIsEncodedIntoEveryLink() {
        let pager = AdminUsersPager(
            page: 2, pageCount: 3, firstShown: 101, lastShown: 200, matchCount: 250, search: "a&b c")
        #expect(pager.pollURL == "/admin/users-data?fragment=rows&page=2&q=a%26b%20c")
        #expect(pager.pageURL(3) == "/admin/users?page=3&q=a%26b%20c")
    }
}
