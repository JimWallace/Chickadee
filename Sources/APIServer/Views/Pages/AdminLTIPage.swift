// APIServer/Views/Pages/AdminLTIPage.swift
//
// GET /admin/lti (docs/lti-1-3.md): the tool URLs an LMS administrator needs
// to register Chickadee, and the registered platforms with add, edit, enable
// and delete.

import Elementary

struct AdminLTIPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    /// False when `PUBLIC_BASE_URL` is unset: the tool URLs are paths only.
    let baseURLConfigured: Bool
    let loginURL: String
    let launchURL: String
    let jwksURL: String
    let platforms: [AdminLTIPlatformRow]
    /// Platforms with launches switched on, for the title's note.
    let enabledPlatformCount: Int
    /// True when a registration failed validation, so the form reopens with
    /// what the admin typed, or when no platform exists yet, so the only way
    /// forward is already open.
    let newPlatformOpen: Bool
    let newFields: LTIPlatformFields

    var body: some HTML {
        BaseLayout(title: "LTI", page: page, flash: flash) {
            AdminTabs(active: .lti, page: page)
            toolSection
            platformsSection
        }
    }

    private var toolSection: some HTML {
        section(.class("page-section")) {
            p(.class("page-crumb")) { "Integrations" }
            div(.class("page-titlebar")) {
                h2 {
                    "LTI "
                    span(.class("text-muted")) { "\(enabledPlatformCount) platform(s) enabled" }
                }
            }
            p(.class("section-intro")) {
                "Give these values to the LMS administrator who registers Chickadee as an LTI 1.3 tool."
            }
            if !baseURLConfigured {
                FlashBanner(.warning) {
                    strong {
                        code { "PUBLIC_BASE_URL" }
                        " is not set,"
                    }
                    " so these are paths. Set it and restart the server."
                }
            }
            div(.class("card section-gap")) {
                dl(.class("detail-grid detail-grid--cells")) {
                    LTIToolURLCell(term: "OIDC login URL", url: loginURL, copyLabel: "Copy the OIDC login URL")
                    LTIToolURLCell(term: "Redirect URL", url: launchURL, copyLabel: "Copy the redirect URL")
                    LTIToolURLCell(term: "Target link URL", url: launchURL, copyLabel: "Copy the target link URL")
                    LTIToolURLCell(term: "Key set URL", url: jwksURL, copyLabel: "Copy the key set URL")
                    div {
                        dt { "Signing algorithm" }
                        dd { code { "RS256" } }
                    }
                }
            }
            p(.class("field-note")) { "Set the link to open in a new window." }
        }
    }

    private var platformsSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Platforms" }
                a(
                    .class("btn action-btn"), .href("#new-platform-panel"),
                    .custom(name: "data-add-target", value: "new-platform-panel")
                ) { "+ Register platform" }
            }
            div(.class(newPlatformOpen ? "add-panel card is-open" : "add-panel card"), .id("new-platform-panel")) {
                form(.method(.post), .action("/admin/lti/platforms"), .class("form-stack")) {
                    CSRFField(token: page.csrfToken)
                    newFields
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Register platform" }
                        button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                    }
                }
            }
            if platforms.isEmpty {
                p(.class("empty")) { "No platforms registered." }
                p(.class("section-note")) { "LTI launches are off until a platform is registered." }
            } else {
                table(.class("results-table section-items section-items--manage")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-status"))
                        col(.class("section-items-actions"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Platform" }
                            th(.custom(name: "scope", value: "col")) { "Detail" }
                            th(.custom(name: "scope", value: "col")) { "Status" }
                            th(.custom(name: "scope", value: "col")) { "Actions" }
                        }
                    }
                    tbody {
                        for platform in platforms {
                            LTIPlatformRow(platform: platform, csrfToken: page.csrfToken)
                        }
                    }
                }
            }
        }
    }
}

/// One tool URL, with a button that copies it.
private struct LTIToolURLCell: HTML {
    let term: String
    let url: String
    let copyLabel: String

    var body: some HTML {
        div {
            dt { term }
            dd {
                code { url }
                " "
                button(
                    .class("btn action-btn action-btn-icon"), .type(.button),
                    .custom(name: "data-copy-url", value: url), .title("Copy"), .ariaLabel(copyLabel)
                ) {
                    Icon("i-copy")
                }
            }
        }
    }
}

/// One registered platform: its summary row, then the row that holds its
/// edit form.
private struct LTIPlatformRow: HTML {
    let platform: AdminLTIPlatformRow
    let csrfToken: String

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile")) { Icon("i-link") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { platform.displayName }
                div(.class("item-details")) {
                    "\(platform.deploymentCount) deployments · "
                    code { platform.issuer }
                    " · client "
                    code { platform.clientID }
                }
            }
            td(.class("item-status")) { statusForm }
            td(.class("item-actions-td")) { actions }
        }
        .attributes(.class("row-muted"), when: !platform.enabled)
        tr {
            td(.custom(name: "colspan", value: "4"), .class("log-entry-cell")) {
                div(
                    .class(platform.editOpen ? "add-panel card is-open" : "add-panel card"),
                    .id("edit-platform-\(platform.id)")
                ) {
                    form(.method(.post), .action("/admin/lti/platforms/\(platform.id)"), .class("form-stack")) {
                        CSRFField(token: csrfToken)
                        platform.fields
                        div(.class("toolbar")) {
                            button(.class("btn btn-primary"), .type(.submit)) { "Save platform" }
                            button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                        }
                    }
                }
            }
        }
    }

    private var statusForm: some HTML {
        form(
            .method(.post), .action("/admin/lti/platforms/\(platform.id)/enabled"), .class("inline-form form-flush")
        ) {
            CSRFField(token: csrfToken)
            label(.class("visually-hidden"), .for("lti-enabled-\(platform.id)")) {
                "Status of \(platform.displayName)"
            }
            span(.class("state-select"), .custom(name: "data-state", value: platform.enabled ? "open" : "closed")) {
                select(
                    .id("lti-enabled-\(platform.id)"), .name("enabled"), .class("form-input"),
                    .dataFlag("ck-submit-on-change")
                ) {
                    option(.value("true")) { "Enabled" }
                        .attributes(.selected, when: platform.enabled)
                    option(.value("false")) { "Disabled" }
                        .attributes(.selected, when: !platform.enabled)
                }
            }
        }
    }

    private var actions: some HTML {
        div(.class("assignment-actions-cell")) {
            a(
                .class("btn action-btn action-btn-icon"), .href("#edit-platform-\(platform.id)"),
                .custom(name: "data-add-target", value: "edit-platform-\(platform.id)"),
                .title("Edit \(platform.displayName)"), .ariaLabel("Edit \(platform.displayName)")
            ) {
                Icon("i-pencil")
            }
            details(.class("ext-details row-menu")) {
                summary(
                    .class("btn action-btn action-btn-icon ext-summary"), .title("More actions"),
                    .ariaLabel("More actions for \(platform.displayName)")
                ) {
                    Icon("i-more")
                }
                div(.class("popover-panel row-menu-panel"), .role("menu")) {
                    form(
                        .method(.post), .action("/admin/lti/platforms/\(platform.id)/delete"),
                        .custom(
                            name: "data-confirm",
                            value:
                                "Delete the platform \(platform.displayName)? Launches from it stop immediately, and the registration cannot be restored."
                        )
                    ) {
                        CSRFField(token: csrfToken)
                        button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                            Icon("i-trash")
                            "Delete platform"
                        }
                    }
                }
            }
        }
    }
}
