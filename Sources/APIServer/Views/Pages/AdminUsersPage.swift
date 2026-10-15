// APIServer/Views/Pages/AdminUsersPage.swift
//
// GET /admin/users: the People tab. Every account, with its role menu and row
// actions. The rows are `UserRows`, which the poll renders too.

import Elementary

struct AdminUsersPage: HTML {
    let page: PageRequestContext
    let users: [AdminUserRow]
    let userCount: Int
    let adminCount: Int

    var body: some HTML {
        BaseLayout(title: "Users", page: page) {
            AdminTabs(active: .users, page: page)
            section(.class("page-section")) {
                div(.class("page-titlebar")) {
                    h2 {
                        "People "
                        span(.class("text-muted")) { "\(userCount) users · \(adminCount) admins" }
                    }
                }
                div(.class("toolbar toolbar--end section-gap")) {
                    span(.class("filter-group")) {
                        label(.class("filter-label"), .for("users-filter")) { "Filter" }
                        input(
                            .id("users-filter"), .class("form-input filter-input"), .type(.search),
                            .placeholder("Filter by name, username or role…"),
                            .data("list-filter", value: "users-table"),
                            .data("list-filter-empty", value: "No users match this filter."))
                    }
                }
                usersTable
            }
            script(.src(page.asset("/list-filter.js"))) {}
            script(.src(page.asset("/sortable-table.js"))) {}
            script(.src(page.asset("/table-poll.js"))) {}
        }
    }

    private var usersTable: some HTML {
        table(
            .class("results-table section-items section-items--manage sortable-table"), .id("users-table"),
            .data("sort-initial", value: "last-seen:desc"), .data("sort-tiebreak", value: "name"),
            .data("poll-url", value: "/admin/users-data?fragment=rows"), .data("poll-interval", value: "5000")
        ) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                col(.class("section-items-seen col-hide-phone"))
                col(.class("section-items-actions"))
            }
            thead {
                tr {
                    th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Person" } }
                    SortHeader(key: "name", type: "text", label: "Name")
                    SortHeader(key: "role", type: "text", label: "Role")
                    SortHeader(key: "last-seen", type: "date", label: "Last seen", hideOnPhone: true)
                    th { "Actions" }
                }
            }
            tbody {
                UserRows(users: users, csrfToken: page.csrfToken)
            }
        }
    }
}
