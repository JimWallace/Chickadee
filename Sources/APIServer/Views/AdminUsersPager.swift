// APIServer/Views/AdminUsersPager.swift
//
// The paging and search state of the admin People table (#2829). The table
// shows one bounded page of the accounts that match the search: `summary` is
// the count line above it, and `body` is the Previous and Next links below
// it. Both stay empty while there is no search and every account fits on one
// page. Every link and the poll URL carry the search.

import Elementary
import Foundation

struct AdminUsersPager: HTML {
    /// The 1-based page shown.
    let page: Int
    let pageCount: Int
    let firstShown: Int
    let lastShown: Int
    /// The accounts that match the search: every account when there is none.
    let matchCount: Int
    /// The trimmed search, or nil when there is none.
    let search: String?

    init(
        page: Int, pageCount: Int, firstShown: Int, lastShown: Int, matchCount: Int, search: String? = nil
    ) {
        self.page = page
        self.pageCount = pageCount
        self.firstShown = firstShown
        self.lastShown = lastShown
        self.matchCount = matchCount
        self.search = search
    }

    init(_ directory: AdminUserDirectoryPage) {
        self.init(
            page: directory.page, pageCount: directory.pageCount,
            firstShown: directory.firstShown, lastShown: directory.lastShown,
            matchCount: directory.matchCount, search: directory.search)
    }

    var isPaged: Bool { pageCount > 1 }

    /// `&q=…` for the search, percent-encoded, or nothing without one.
    private var searchQuery: String {
        guard let search else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return "&q=" + (search.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    /// The poll refreshes the page and the search that are shown.
    var pollURL: String { "/admin/users-data?fragment=rows&page=\(page)\(searchQuery)" }

    func pageURL(_ target: Int) -> String { "/admin/users?page=\(target)\(searchQuery)" }

    /// The count line above the table. The table sorts and filters on the
    /// client, so both cover only the rows of this page (the audit page
    /// avoids a client sort for that reason; this table keeps it, because a
    /// sort within one page is still useful). The line says that Enter in
    /// the filter box searches every account on the server, and the live
    /// filter's no-match text says "on this page".
    @HTMLBuilder var summary: some HTML {
        if let search {
            p(.class("text-muted")) {
                if matchCount == 0 {
                    "No users match “\(search)”."
                } else if isPaged {
                    "Showing \(firstShown)–\(lastShown) of \(matchCount) users that match “\(search)”."
                } else {
                    "\(matchCount) \(matchCount == 1 ? "user matches" : "users match") “\(search)”."
                }
            }
        } else if isPaged {
            p(.class("text-muted")) {
                "Showing \(firstShown)–\(lastShown) of \(matchCount); press Enter to search every account."
            }
        }
    }

    /// The Previous and Next links below the table.
    var body: some HTML {
        if isPaged {
            nav(.class("toolbar toolbar--end section-gap"), .ariaLabel("Pages of people")) {
                if page > 1 {
                    a(.class("btn action-btn"), .href(pageURL(page - 1))) { "Previous" }
                }
                if page < pageCount {
                    a(.class("btn action-btn"), .href(pageURL(page + 1))) { "Next" }
                }
            }
        }
    }
}
