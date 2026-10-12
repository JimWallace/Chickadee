// APIServer/Views/Pages/AdminBrightspacePage.swift
//
// GET /admin/brightspace: the deployment's one LEARN (D2L) service-account
// connection. The app credentials come from the environment; this page shows
// whether a user key is held and sets or clears the stored one.

import Elementary

struct AdminBrightspacePage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    /// True when the app credentials are in the environment.
    let configured: Bool
    /// True when a live client exists, from a stored or an environment key.
    let authorized: Bool
    let baseURL: String?
    let identityName: String?
    /// "authorized" (stored key), "env" (BRIGHTSPACE_USER_KEY), or "none".
    let keySource: String
    let capturedAt: String?

    private var storedKey: Bool { keySource == "authorized" }

    var body: some HTML {
        BaseLayout(title: "LEARN", page: page, flash: flash) {
            AdminTabs(active: .brightspace, page: page)
            section(.class("page-section")) {
                p(.class("page-crumb")) { "Integrations" }
                div(.class("page-titlebar")) {
                    h2 {
                        "LEARN "
                        if configured {
                            AuthorizationPill(authorized: authorized)
                        }
                    }
                    if configured, authorized {
                        toolbar
                    }
                }
                p(.class("section-intro")) {
                    "Grade sync for every course runs as one D2L service account. App credentials come from the server environment."
                }
                if !configured {
                    div(.class("flash flash-warning"), .role("status")) {
                        strong { "Not configured." }
                        " Set "
                        code { "BRIGHTSPACE_URL" }
                        ", "
                        code { "BRIGHTSPACE_APP_ID" }
                        " and "
                        code { "BRIGHTSPACE_APP_KEY" }
                        ", then reload."
                    }
                } else {
                    statusCard
                    if authorized {
                        div(.class("add-panel card"), .id("replace-key-panel")) { keyForm }
                    } else {
                        div(.id("replace-key-panel")) { keyForm }
                    }
                    p(.class("section-note")) {
                        "Instructors map grade items on their course’s LEARN tab. This page only sets the shared connection."
                    }
                }
            }
        }
    }

    private var toolbar: some HTML {
        div(.class("toolbar")) {
            form(.method(.post), .action("/admin/brightspace/test"), .class("form-flush")) {
                CSRFField(token: page.csrfToken)
                button(.class("btn action-btn"), .type(.submit)) { "Test connection" }
            }
            details(.class("add-section-details popup-anchor")) {
                summary(
                    .class("btn action-btn action-btn-icon summary-btn"), .title("More actions"),
                    .ariaLabel("More actions for LEARN")
                ) {
                    Icon("i-more")
                }
                div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                    a(
                        .class("row-menu-item"), .href("#replace-key-panel"), .role("menuitem"),
                        .custom(name: "data-add-target", value: "replace-key-panel")
                    ) {
                        Icon("i-key")
                        "Replace user key…"
                    }
                    if storedKey {
                        form(
                            .method(.post), .action("/admin/brightspace/clear"),
                            .custom(
                                name: "data-confirm",
                                value:
                                    "Clear the stored LEARN authorization? Grade sync reverts to the environment key if one is set, otherwise it stops. You can re-authorize from this page."
                            )
                        ) {
                            CSRFField(token: page.csrfToken)
                            button(
                                .class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")
                            ) {
                                Icon("i-trash")
                                "Clear authorization"
                            }
                        }
                    }
                }
            }
        }
    }

    private var statusCard: some HTML {
        div(.class("card section-gap")) {
            dl(.class("detail-grid")) {
                dt { "Status" }
                dd {
                    AuthorizationPill(authorized: authorized)
                    if authorized {
                        span(.class("card-meta")) {
                            if storedKey {
                                "Key set on this page · overrides "
                                code { "BRIGHTSPACE_USER_KEY" }
                            } else {
                                "Using key from environment"
                            }
                        }
                    }
                }
                dt { "LMS" }
                dd { code { baseURL ?? "" } }
                if let identityName {
                    dt { "Authorized as" }
                    dd {
                        identityName
                        if let capturedAt {
                            " "
                            span(.class("card-meta")) { capturedAt }
                        }
                    }
                }
            }
        }
    }

    private var keyForm: some HTML {
        form(.method(.post), .action("/admin/brightspace/set-credentials"), .class("form popup-form")) {
            CSRFField(token: page.csrfToken)
            p(.class("section-note")) {
                "Paste the "
                strong { "User ID" }
                " and "
                strong { "User Key" }
                " from your institution’s credential service."
            }
            CredentialField(label: "User ID", name: "userID")
            CredentialField(label: "User Key", name: "userKey")
            div(.class("toolbar")) {
                button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Save & verify" }
                if authorized {
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }
}

/// The Authorized or Not authorized pill.
private struct AuthorizationPill: HTML {
    let authorized: Bool

    var body: some HTML {
        if authorized {
            span(.class("tier tier-open")) { "Authorized" }
        } else {
            span(.class("tier tier-closed")) { "Not authorized" }
        }
    }
}

/// One pasted credential: a plain text input with no autofill.
private struct CredentialField: HTML {
    let label: String
    let name: String

    var body: some HTML {
        Elementary.label(.class("form-label")) {
            label
            input(
                .class("form-input"), .type(.text), .name(name), .autocomplete("off"),
                .custom(name: "spellcheck", value: "false"), .required)
        }
    }
}
