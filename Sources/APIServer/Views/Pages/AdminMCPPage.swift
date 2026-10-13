// APIServer/Views/Pages/AdminMCPPage.swift
//
// GET /admin/mcp: the content-authoring MCP endpoint's mode and token
// settings, the local `mcp` service accounts with mint, enrol and delete, and
// every browser-flow agent grant with revoke.

import Elementary

struct AdminMCPPage: HTML {
    let page: PageRequestContext
    /// True only when MCP is mounted, the signing authority is loaded, and the
    /// issuer and resource resolve, so tokens can actually be minted.
    let enabled: Bool
    /// False in read_only mode: the page hides the read+write mint option and
    /// shows a read-only banner.
    let writeAllowed: Bool
    let issuer: String?
    let resource: String?
    let tokenTTLSeconds: Int
    /// True only in local-auth mode, where manual service accounts are the
    /// mechanism. With SSO, instructors authorize agents in the browser.
    let showServiceAccounts: Bool
    let accounts: [AdminMCPAccountRow]
    /// Browser-flow OAuth grants (all of them: the admin view), with revoke.
    let grants: [AgentGrantRow]
    /// Set immediately after a mint so the page can show the token once.
    let mintedToken: String?
    let mintedFor: String?
    let mintedScopes: String?
    /// A short error key surfaced as a banner (e.g. "username_taken").
    let error: String?
    /// The mode pill: "Read/write", "Read-only" or "Inactive".
    let modeLabel: String
    /// Token lifetime in words ("1 hour", "30 minutes").
    let tokenLifetimeText: String

    private var modeTier: String {
        if !enabled { return "tier-danger" }
        return writeAllowed ? "tier-open" : "tier-preview"
    }

    private var errorMessage: String? {
        switch error {
        case "username_required": "A username is required."
        case "username_taken": "That username is already in use."
        case "mcp_disabled": "Cannot mint a token while the MCP endpoint is inactive."
        case "enroll_failed": "Could not update the account's course enrollment."
        default: nil
        }
    }

    var body: some HTML {
        BaseLayout(title: "MCP", page: page) {
            AdminTabs(active: .mcp, page: page)
            endpointSection
            if showServiceAccounts {
                AdminMCPAccountsSection(
                    accounts: accounts, enabled: enabled, writeAllowed: writeAllowed, csrfToken: page.csrfToken)
            }
            AdminMCPGrantsSection(grants: grants, csrfToken: page.csrfToken)
            PageStyle(
                """
                .mcp-token-caption { margin: .1rem 0 .5rem; }
                """
            )
        }
    }

    private var endpointSection: some HTML {
        section(.class("page-section")) {
            p(.class("page-crumb")) { "Integrations" }
            div(.class("page-titlebar")) {
                h2 {
                    "MCP "
                    span(.class("tier \(modeTier)")) { modeLabel }
                }
            }
            if !enabled {
                // A page-state banner, not a one-shot flash: it shows on every
                // load while MCP is off.
                FlashBanner(.warning) {
                    strong { "MCP is inactive." }
                    " Set "
                    code { "MCP_MODE" }
                    " and "
                    code { "PUBLIC_BASE_URL" }
                    ", then restart."
                }
            } else if !writeAllowed {
                FlashBanner(.warning) {
                    strong { "Read-only mode." }
                    " Agents can read course content but not edit it; tokens carry "
                    code { "content:read" }
                    "."
                }
            }
            if let errorMessage {
                div(.class("form-error"), .role("alert")) { errorMessage }
            }
            if let mintedToken {
                mintedTokenBanner(mintedToken)
            }
            if enabled {
                div(.class("card section-gap")) {
                    dl(.class("detail-grid")) {
                        dt { "Issuer" }
                        dd { code { issuer ?? "" } }
                        dt { "Resource" }
                        dd { code { resource ?? "" } }
                        dt { "Token lifetime" }
                        dd {
                            "\(tokenLifetimeText) "
                            span(.class("card-meta")) {
                                "Stateless: deleting an account doesn’t revoke issued tokens"
                            }
                        }
                    }
                }
            }
        }
    }

    /// The token, shown once, right after a mint. It carries a textarea, so it
    /// is a `FlashBanner` of its own, not a one-shot flash message.
    private func mintedTokenBanner(_ token: String) -> some HTML {
        FlashBanner(.success) {
            p(.class("mcp-token-caption")) {
                strong { "Access token for \(mintedFor ?? "")" }
                " · scopes: "
                code { mintedScopes ?? "" }
                " · expires after \(tokenTTLSeconds)s. Copy it now — it is shown only once."
            }
            textarea(.readonly, .rows(4), .class("form-input textarea-mono"), .dataFlag("ck-select-all")) {
                token
            }
        }
    }
}

/// The local service accounts, with the form that creates one.
private struct AdminMCPAccountsSection: HTML {
    let accounts: [AdminMCPAccountRow]
    let enabled: Bool
    let writeAllowed: Bool
    let csrfToken: String

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "MCP service accounts" }
                newAccount
            }
            if accounts.isEmpty {
                p(.class("text-muted")) { "No MCP accounts yet." }
            } else {
                table(.class("results-table section-items section-items--manage")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-actions"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Account" }
                            th(.custom(name: "scope", value: "col")) { "Detail" }
                            th(.custom(name: "scope", value: "col")) { "Actions" }
                        }
                    }
                    tbody {
                        for account in accounts {
                            AdminMCPAccountRowView(
                                account: account, enabled: enabled, writeAllowed: writeAllowed, csrfToken: csrfToken)
                        }
                    }
                }
            }
        }
    }

    private var newAccount: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "+ New account "
                Icon("i-chevron-down")
            }
            div(.class("add-section-popup card suite-section-popup"), .role("dialog"), .ariaLabel("New account")) {
                form(.method(.post), .action("/admin/mcp/accounts"), .class("form popup-form")) {
                    CSRFField(token: csrfToken)
                    label(.class("form-label"), .for("mcp-new-account")) {
                        "Create account"
                        input(
                            .id("mcp-new-account"), .class("form-input"), .type(.text), .name("username"), .required,
                            .autocomplete("new-password"), .placeholder("course-bot"))
                        span(.class("field-note field-note--muted")) {
                            "A new account has no course access until you enrol it in a course."
                        }
                    }
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Create account" }
                    }
                }
            }
        }
    }
}

/// One service account: its courses, the mint menu and the row menu.
private struct AdminMCPAccountRowView: HTML {
    let account: AdminMCPAccountRow
    let enabled: Bool
    let writeAllowed: Bool
    let csrfToken: String

    private var tokenAction: String { "/admin/mcp/accounts/\(account.id)/token" }

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .custom(name: "data-kind", value: "notebook")) { Icon("i-cpu") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { code { account.username } }
                div(.class(account.coursesText.isEmpty ? "item-details item-details--danger" : "item-details")) {
                    "created "
                    span(.class("js-relative-time"), .custom(name: "data-iso", value: account.createdAt)) {
                        account.createdAt
                    }
                    " · \(account.coursesText.isEmpty ? "No course access" : account.coursesText)"
                }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    if enabled {
                        if writeAllowed {
                            mintMenu
                        } else {
                            form(.method(.post), .action(tokenAction), .class("form-flush")) {
                                CSRFField(token: csrfToken)
                                input(.type(.hidden), .name("scope"), .value("read"))
                                button(.class("btn action-btn"), .type(.submit)) { "Mint token" }
                            }
                        }
                    }
                    rowMenu
                }
            }
        }
    }

    private var mintMenu: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "Mint token "
                Icon("i-chevron-down")
            }
            div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                form(.method(.post), .action(tokenAction)) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("scope"), .value("readwrite"))
                    button(.class("row-menu-item"), .type(.submit), .role("menuitem")) { "Read + write" }
                }
                form(.method(.post), .action(tokenAction)) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("scope"), .value("read"))
                    button(.class("row-menu-item"), .type(.submit), .role("menuitem")) { "Read only" }
                }
            }
        }
    }

    private var rowMenu: some HTML {
        RowMenu(for: account.username) {
            if !account.enrollableCourses.isEmpty {
                form(
                    .method(.post), .action("/admin/mcp/accounts/\(account.id)/enroll"), .class("field-inline")
                ) {
                    CSRFField(token: csrfToken)
                    label(.class("visually-hidden"), .for("enroll-\(account.id)")) {
                        "Enrol \(account.username) in a course"
                    }
                    select(.id("enroll-\(account.id)"), .name("courseID"), .class("form-input")) {
                        for course in account.enrollableCourses {
                            option(.value(course.id)) { AdminMCPCourseLabel(course: course) }
                        }
                    }
                    button(.class("btn action-btn"), .type(.submit)) { "Enrol" }
                }
            }
            for course in account.enrolledCourses {
                form(.method(.post), .action("/admin/mcp/accounts/\(account.id)/unenroll")) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("courseID"), .value(course.id))
                    button(.class("row-menu-item"), .type(.submit), .role("menuitem")) {
                        "Remove from "
                        AdminMCPCourseLabel(course: course)
                    }
                }
            }
            form(
                .method(.post), .action("/admin/mcp/accounts/\(account.id)/delete"),
                .custom(
                    name: "data-confirm",
                    value:
                        "Delete the MCP account \(account.username)? It loses access immediately. Tokens it already minted stay valid until they expire, and the account cannot be restored."
                )
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    Icon("i-trash")
                    "Delete account"
                }
            }
        }
    }
}

/// A course's code, then its term when it has one.
private struct AdminMCPCourseLabel: HTML {
    let course: AdminCourseRef

    var body: some HTML {
        course.code
        if let term = course.termLabel {
            " \(term)"
        }
    }
}

/// The browser-flow agent grants, with revoke on each that still works.
private struct AdminMCPGrantsSection: HTML {
    let grants: [AgentGrantRow]
    let csrfToken: String

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "Connected agents" }
            if grants.isEmpty {
                p(.class("text-muted")) { "No agents have connected yet." }
            } else {
                table(.class("results-table section-items section-items--manage")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-count"))
                        col(.class("section-items-count"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Agent" }
                            th(.custom(name: "scope", value: "col")) { "Detail" }
                            th(.custom(name: "scope", value: "col")) { "Status" }
                            th(.custom(name: "scope", value: "col")) { "Actions" }
                        }
                    }
                    tbody {
                        for grant in grants {
                            AdminMCPGrantRow(grant: grant, csrfToken: csrfToken)
                        }
                    }
                }
            }
        }
    }
}

/// One agent grant.
private struct AdminMCPGrantRow: HTML {
    let grant: AgentGrantRow
    let csrfToken: String

    private var statusTier: String {
        if grant.canRevoke { return "tier-open" }
        return grant.revoked ? "tier-closed" : "tier-preview"
    }

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .custom(name: "data-kind", value: "notebook")) { Icon("i-cpu") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { grant.agentName }
                div(.class("item-details")) {
                    "authorized by "
                    code { grant.owner ?? "" }
                    " · last used "
                    if let lastUsedAt = grant.lastUsedAt {
                        span(.class("js-relative-time"), .custom(name: "data-iso", value: lastUsedAt)) { lastUsedAt }
                    } else {
                        "never"
                    }
                    " · expires "
                    span(.class("js-relative-time"), .custom(name: "data-iso", value: grant.expiresAt)) {
                        grant.expiresAt
                    }
                    " · "
                    code { grant.scope }
                }
            }
            td(.class("item-status")) {
                span(.class("tier \(statusTier)")) { grant.statusLabel }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    if grant.canRevoke {
                        revokeMenu
                    } else {
                        span(.class("row-menu-spacer"), .ariaHidden) {}
                    }
                }
            }
        }
        .attributes(.class("row-muted"), when: !grant.canRevoke)
    }

    private var revokeMenu: some HTML {
        RowMenu(for: grant.agentName) {
            form(
                .method(.post), .action("/agents/\(grant.id)/revoke"),
                .custom(
                    name: "data-confirm",
                    value:
                        "Revoke this agent? It loses access immediately. The audit record of what it did is kept, and the agent can be authorized again from its client."
                )
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    "Revoke agent"
                }
            }
        }
    }
}
