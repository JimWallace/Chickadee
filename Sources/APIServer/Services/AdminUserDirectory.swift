// APIServer/Services/AdminUserDirectory.swift
//
// One bounded page of the admin People list (#2829). The Users tab polls
// every five seconds, so each poll reads at most `pageSize` users instead
// of every account on the deployment.

import Core
import Fluent
import FluentSQL
import Foundation
import SQLKit

/// The users on one page of the admin People list, with the counts the page
/// header shows.
struct AdminUserDirectoryPage: Sendable {
    let users: [APIUser]
    /// Every account on the deployment, searched or not.
    let total: Int
    /// Every admin account on the deployment, searched or not.
    let adminCount: Int
    /// The accounts that match the search: `total` when there is none.
    let matchCount: Int
    /// The trimmed search, or nil when there is none.
    let search: String?
    /// The 1-based page shown, after clamping to the pages that exist.
    let page: Int
    let pageSize: Int

    var pageCount: Int { max(1, (matchCount + pageSize - 1) / pageSize) }
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
    ///
    /// `search` keeps the users whose username, display name or role contains
    /// it, ignoring case, before the page is cut, so a search reaches every
    /// account and not only the page shown.
    static func page(
        _ requested: Int, search rawSearch: String? = nil, pageSize: Int = pageSize, on db: any Database
    ) async throws -> AdminUserDirectoryPage {
        let search = normalizedSearch(rawSearch)
        func matching() -> QueryBuilder<APIUser> {
            let query = APIUser.query(on: db)
            if let search {
                let pattern = "%" + likeEscaped(search) + "%"
                query.filter(
                    .sql(
                        embed:
                            "(username ILIKE \(bind: pattern) OR display_name ILIKE \(bind: pattern) OR role ILIKE \(bind: pattern))"
                    ))
            }
            return query
        }

        async let totalCount = APIUser.query(on: db).count()
        async let admins = APIUser.query(on: db).filter(\.$role == UserRole.admin.rawValue).count()
        async let matches = matching().count()
        let (total, adminCount, matchCount) = try await (totalCount, admins, matches)

        let pageCount = max(1, (matchCount + pageSize - 1) / pageSize)
        let page = min(max(1, requested), pageCount)
        let users = try await matching()
            .sort(.sql(unsafeRaw: "last_seen_at DESC NULLS LAST"))
            .sort(.sql(unsafeRaw: "lower(username)"))
            .sort(\.$username)
            .sort(.sql(unsafeRaw: "created_at ASC NULLS FIRST"))
            .sort(\.$id)
            .offset((page - 1) * pageSize)
            .limit(pageSize)
            .all()
        return AdminUserDirectoryPage(
            users: users, total: total, adminCount: adminCount, matchCount: matchCount,
            search: search, page: page, pageSize: pageSize)
    }

    /// The search with surrounding white space removed, or nil when nothing
    /// is left.
    static func normalizedSearch(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Escapes the LIKE wildcards, so `%` and `_` in a search match
    /// themselves. Postgres reads a backslash as the LIKE escape character.
    static func likeEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
