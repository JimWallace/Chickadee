// APIServer/Views/AdminUsersPager.swift
//
// The paging of the admin People table (#2829). The table shows one bounded
// page of accounts: `summary` is the count line above it, and `body` is the
// Previous and Next links below it. Nothing renders while every account fits
// on one page.

import Elementary

struct AdminUsersPager: HTML {
    /// The 1-based page shown.
    let page: Int
    let pageCount: Int
    let firstShown: Int
    let lastShown: Int
    let total: Int

    init(page: Int, pageCount: Int, firstShown: Int, lastShown: Int, total: Int) {
        self.page = page
        self.pageCount = pageCount
        self.firstShown = firstShown
        self.lastShown = lastShown
        self.total = total
    }

    init(_ directory: AdminUserDirectoryPage) {
        self.init(
            page: directory.page, pageCount: directory.pageCount,
            firstShown: directory.firstShown, lastShown: directory.lastShown, total: directory.total)
    }

    /// The poll refreshes the page that is shown, not page 1.
    var pollURL: String { "/admin/users-data?fragment=rows&page=\(page)" }

    var isPaged: Bool { pageCount > 1 }

    /// The count line above the table. The table sorts and filters on the
    /// client, so both cover only the rows of this page, and the line says so
    /// (the audit page avoids a client sort for the same reason; this table
    /// keeps it, because a sort within one page is still useful).
    @HTMLBuilder var summary: some HTML {
        if isPaged {
            p(.class("text-muted")) {
                "Showing \(firstShown)–\(lastShown) of \(total). Sort and filter apply to this page."
            }
        }
    }

    /// The Previous and Next links below the table.
    var body: some HTML {
        if isPaged {
            nav(.class("toolbar toolbar--end section-gap"), .ariaLabel("Pages of people")) {
                if page > 1 {
                    a(.class("btn action-btn"), .href("/admin/users?page=\(page - 1)")) { "Previous" }
                }
                if page < pageCount {
                    a(.class("btn action-btn"), .href("/admin/users?page=\(page + 1)")) { "Next" }
                }
            }
        }
    }
}
