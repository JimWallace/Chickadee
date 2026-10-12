// APIServer/Views/UserRows.swift
//
// The rows of the admin People table. `AdminUsersPage` renders them in the
// table, and `GET /admin/users-data?fragment=rows` renders them alone for
// `table-poll.js`. Both render this one struct, so the poll cannot drift from
// the page. A row's bird needs the avatar sprite, which the page renders once.

import Elementary

struct UserRows: HTML {
    let users: [AdminUserRow]
    let csrfToken: String

    var body: some HTML {
        for user in users {
            UserRow(user: user, csrfToken: csrfToken)
        }
    }
}

/// One person: bird, name, role menu, last seen, and the row actions.
struct UserRow: HTML {
    let user: AdminUserRow
    let csrfToken: String

    /// The display name, when there is one to show.
    private var displayName: String? {
        guard let name = user.displayName, !name.isEmpty else { return nil }
        return name
    }

    private var lastSeenAt: String? {
        guard let seen = user.lastSeenAt, !seen.isEmpty else { return nil }
        return seen
    }

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                if user.hasAvatar, let avatar = user.avatar {
                    Avatar(avatar: avatar)
                }
            }
            td(.class("item-main"), .data("sort-value", value: displayName ?? user.username)) {
                if let displayName {
                    div(.class("item-title")) { displayName }
                } else {
                    div(.class("item-title")) { code { user.username } }
                }
                div(.class("item-details")) {
                    if displayName != nil {
                        code { user.username }
                        " · "
                    }
                    " joined "
                    span(.class("js-relative-time"), .data("iso", value: user.createdAt)) { user.createdAt }
                }
            }
            td(.class("item-status"), .data("sort-value", value: user.role)) {
                if user.role == "mcp" {
                    span(.class("tier tier-preview")) { "MCP service" }
                } else {
                    roleForm
                }
            }
            td(.class("col-hide-phone js-relative-time"), .data("iso", value: user.lastSeenAt ?? "")) {
                lastSeenAt ?? "—"
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    a(
                        .href("/admin/users/\(user.id)"), .class("btn action-btn action-btn-icon"),
                        .title("Manage user"), .ariaLabel("Manage user")
                    ) {
                        Icon("i-pencil")
                    }
                    rowMenu
                }
            }
        }
    }

    private var roleForm: some HTML {
        form(.method(.post), .action("/admin/users/\(user.id)/role"), .class("inline-form form-flush")) {
            CSRFField(token: csrfToken)
            label(.class("visually-hidden"), .for("role-\(user.id)")) { "Role for \(user.username)" }
            span(.class("state-select"), .data("state", value: user.role)) {
                select(.id("role-\(user.id)"), .name("role"), .class("form-input"), .dataFlag("ck-submit-on-change")) {
                    option(.value("user")) { "User" }
                        .attributes(.selected, when: user.role == "user")
                    option(.value("admin")) { "Admin" }
                        .attributes(.selected, when: user.role == "admin")
                }
                .attributes(.disabled, when: user.isCurrentUser)
            }
        }
    }

    private var rowMenu: some HTML {
        details(.class("ext-details row-menu")) {
            summary(
                .class("btn action-btn action-btn-icon ext-summary"), .title("More actions"),
                .ariaLabel("More actions for \(user.username)")
            ) {
                Icon("i-more")
            }
            div(.class("popover-panel row-menu-panel"), .role("menu")) {
                form(
                    .method(.post), .action("/admin/users/\(user.id)/delete"),
                    .data(
                        "confirm",
                        value:
                            "Delete @\(user.username)? They lose access immediately and their enrollments are removed. Their submissions are kept, and a returning user gets a new account rather than this one."
                    )
                ) {
                    CSRFField(token: csrfToken)
                    button(
                        .class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem"),
                        .ariaLabel("Delete user")
                    ) {
                        Icon("i-trash")
                        "Delete user"
                    }
                }
            }
        }
    }
}
