// APIServer/Services/AdminUserDirectory.swift
//
// One bounded page of the admin People list (#2829). The Users tab polls
// every five seconds, so each poll reads at most `pageSize` users instead
// of every account on the deployment.

import Core
import Fluent
import FluentSQL
import Foundation

/// The users on one page of the admin People list, with the counts the page
/// header shows.
struct AdminUserDirectoryPage: Sendable {
    let users: [APIUser]
    /// Every account on the deployment.
    let total: Int
    /// Every admin account on the deployment.
    let adminCount: Int
    /// The 1-based page shown, after clamping to the pages that exist.
    let page: Int
    let pageSize: Int

    var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }
    /// The 1-based position of the first user shown, or 0 for an empty page.
    var firstShown: Int { users.isEmpty ? 0 : (page - 1) * pageSize + 1 }
    var lastShown: Int { (page - 1) * pageSize + users.count }
}

enum AdminUserDirectory {
    /// The people shown on one page of the Users tab.
    static let pageSize = 100

    /// Loads one page of users in the People order: most recently seen
    /// first, users never seen last, then by username, then by join date.
    /// The database sorts and limits, so the cost of a poll does not grow
    /// with the number of accounts. Usernames compare case-insensitively as
    /// text, so `user10` sorts before `user2`; the old in-memory sort was
    /// numeric-aware. Only users with the same last-seen time (in practice,
    /// users never seen) are ordered by username.
    static func page(
        _ requested: Int, pageSize: Int = pageSize, on db: any Database
    ) async throws
        -> AdminUserDirectoryPage
    {
        async let totalCount = APIUser.query(on: db).count()
        async let admins = APIUser.query(on: db).filter(\.$role == UserRole.admin.rawValue).count()
        let (total, adminCount) = try await (totalCount, admins)

        let pageCount = max(1, (total + pageSize - 1) / pageSize)
        let page = min(max(1, requested), pageCount)
        let users = try await APIUser.query(on: db)
            .sort(.sql(unsafeRaw: "last_seen_at DESC NULLS LAST"))
            .sort(.sql(unsafeRaw: "lower(username)"))
            .sort(\.$username)
            .sort(.sql(unsafeRaw: "created_at ASC NULLS FIRST"))
            .sort(\.$id)
            .offset((page - 1) * pageSize)
            .limit(pageSize)
            .all()
        return AdminUserDirectoryPage(
            users: users, total: total, adminCount: adminCount, page: page, pageSize: pageSize)
    }
}
