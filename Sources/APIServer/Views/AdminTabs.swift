// APIServer/Views/AdminTabs.swift
//
// The admin-area chrome from `_admin-tabs.leaf`: the version banner, the
// page's hidden h1 and the tab bar. Every admin tabbed page opens with
// `AdminTabs`, and no other view writes the `admin-tab` classes (SwiftLint
// `elementary_tabs_only_in_component`).
//
// Overview, Health Alerts and People are direct links. The other pages group
// into the Data and Integrations menus, which use the nav-dropdown idiom
// (app.js drives every [data-nav-dropdown]). aria-current goes on the item
// that is the current page. A menu toggle navigates nowhere, so it carries
// data-group-current instead.

import Elementary

/// One admin page. The raw value is the `activeAdminTab` value the Leaf pages
/// set, so a Leaf page and a Swift page name a tab the same way.
enum AdminTab: String, CaseIterable, Sendable {
    case overview, alerts, users, storage, retention, audit, brightspace, mcp, lti, github

    /// The hidden h1: the group, then the page.
    var heading: String {
        switch self {
        case .overview: "Overview"
        case .alerts: "Health Alerts"
        case .users: "People"
        case .storage: "Data — Storage"
        case .retention: "Data — Retention"
        case .audit: "Data — Audit Log"
        case .brightspace: "Integrations — LEARN"
        case .mcp: "Integrations — MCP"
        case .lti: "Integrations — LTI"
        case .github: "Integrations — GitHub"
        }
    }

    fileprivate var href: String {
        self == .overview ? "/admin" : "/admin/\(rawValue)"
    }
}

struct AdminTabs: HTML {
    let active: AdminTab
    let page: PageRequestContext

    var body: some HTML {
        p(.class("admin-version-banner")) { "Chickadee v\(page.appVersion)" }
        h1(.class("visually-hidden")) { "Admin — \(active.heading)" }
        nav(.class("admin-tabs"), .ariaLabel("Admin sections")) {
            tab(.overview, "Overview")
            tab(.alerts, "Health Alerts")
            tab(.users, "People")
            menu("Data", [(.storage, "Storage"), (.retention, "Retention"), (.audit, "Audit Log")])
            // The MCP item is hidden when MCP is off, but /admin/mcp still
            // marks Integrations as the current group.
            menu(
                "Integrations",
                [(.brightspace, "LEARN"), (.mcp, "MCP"), (.lti, "LTI"), (.github, "GitHub")],
                hiding: page.mcpEnabled ? [] : [.mcp])
        }
    }

    private func tab(_ tab: AdminTab, _ label: String) -> some HTML {
        a(.class("admin-tab"), .href(tab.href)) { label }
            .attributes(.ariaCurrent("page"), when: tab == active)
    }

    private func menu(
        _ label: String, _ items: [(tab: AdminTab, label: String)], hiding hidden: Set<AdminTab> = []
    ) -> some HTML {
        div(.class("nav-dropdown"), .dataFlag("nav-dropdown")) {
            button(
                .type(.button), .class("admin-tab nav-dropdown-toggle"),
                .ariaHasPopup(true), .ariaExpanded(false)
            ) {
                span { label }
                span(.class("nav-dropdown-caret"), .ariaHidden) { "▾" }
            }
            .attributes(.dataFlag("group-current"), when: items.contains { $0.tab == active })
            div(.class("nav-dropdown-menu"), .role("menu")) {
                for item in items where !hidden.contains(item.tab) {
                    a(.class("nav-dropdown-item"), .role("menuitem"), .href(item.tab.href)) { item.label }
                        .attributes(.class("nav-dropdown-item-active"), .ariaCurrent("page"), when: item.tab == active)
                }
            }
        }
    }
}
