// APIServer/Views/Pages/AdminGitHubPage.swift
//
// GET /admin/github: the deployment's GitHub App (docs/github-submissions.md).
// With an App registered, the page shows it and what GitHub grants it. With
// none, it builds the manifest form that creates one on GitHub.

import Elementary

struct AdminGitHubPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    /// False when `PUBLIC_BASE_URL` is unset: the manifest needs absolute URLs.
    let baseURLConfigured: Bool
    /// The registered App, or nil when none is registered.
    let app: AdminGitHubAppDetails?
    /// True when an App is registered but its secrets file is missing or
    /// unreadable (#1771); `secretsMissing` says which, and `secretsPath` is
    /// the file the admin must restore.
    let secretsUnavailable: Bool
    let secretsMissing: Bool
    let secretsPath: String
    /// The App's options and whether GitHub grants each (#1776). Empty when
    /// there is no App, its secrets are unavailable, or GitHub did not answer.
    let capabilities: [GitHubCapabilityRow]
    /// True when at least one option is not granted.
    let capabilitiesIncomplete: Bool
    /// True when the App's secrets are readable but GitHub did not say what
    /// the App may do.
    let capabilitiesUnknown: Bool
    /// The manifest form, or nil when an App is registered or the form cannot
    /// be built.
    let creation: GitHubAppCreationContext?
    /// The organization the admin typed, so the field keeps it.
    let organization: String
    /// True when an option was set, so the disclosure stays open.
    let organizationOpen: Bool
    let courseRepositories: Bool
    let pushEvents: Bool
    let commitStatuses: Bool

    var body: some HTML {
        BaseLayout(title: "GitHub", page: page, flash: flash) {
            AdminTabs(active: .github, page: page)
            section(.class("page-section")) {
                p(.class("page-crumb")) { "Integrations" }
                div(.class("page-titlebar")) {
                    h2 {
                        "GitHub App "
                        if app == nil {
                            span(.class("tier tier-closed")) { "Not registered" }
                        } else if secretsUnavailable {
                            span(.class("tier tier-danger")) { "Unavailable" }
                        } else {
                            span(.class("tier tier-open")) { "Registered" }
                        }
                    }
                    if let app {
                        AdminGitHubAppToolbar(app: app, csrfToken: page.csrfToken)
                    }
                }
                if let app {
                    registered(app)
                } else {
                    unregistered
                }
            }
        }
    }

    @HTMLBuilder private func registered(_ app: AdminGitHubAppDetails) -> some HTML {
        p(.class("section-intro")) { "Chickadee reads student repositories through this App." }
        if secretsUnavailable {
            FlashBanner(.warning) {
                strong { "Secrets file \(secretsMissing ? "missing" : "unreadable")." }
                " GitHub submission and webhooks are off until "
                code { secretsPath }
                " is restored, or the App is removed and registered again."
            }
        }
        div(.class("card section-gap")) {
            dl(.class("detail-grid detail-grid--cells")) {
                AdminGitHubDetailCell(term: "Name") { app.name }
                AdminGitHubDetailCell(term: "App ID") { code { "\(app.appID)" } }
                AdminGitHubDetailCell(term: "Client ID") { code { app.clientID } }
                if let owner = app.owner {
                    AdminGitHubDetailCell(term: "Owner") { owner }
                }
                for capability in capabilities {
                    AdminGitHubDetailCell(term: capability.label) {
                        if capability.granted {
                            span(.class("tier tier-open")) { "Granted" }
                        } else {
                            span(.class("tier tier-closed")) { "Not granted" }
                        }
                    }
                }
            }
        }
        if capabilitiesIncomplete {
            p(.class("section-note")) {
                "To use an option that is not granted, add it in the App's settings on GitHub."
            }
        }
        if capabilitiesUnknown {
            p(.class("section-note")) { "The App's permissions could not be read from GitHub." }
        }
    }

    @HTMLBuilder private var unregistered: some HTML {
        p(.class("empty")) { "No GitHub App registered." }
        p(.class("section-note")) {
            "GitHub submission is off until an App is registered, which must wait for the privacy review."
        }
        if !baseURLConfigured {
            FlashBanner(.warning) {
                code { "PUBLIC_BASE_URL" }
                " is not set, so GitHub cannot return to this server. Set it and restart the server."
            }
        }
        if let creation {
            form(.method(.post), .action(creation.actionURL), .class("form-stack section-gap")) {
                input(.type(.hidden), .name("manifest"), .value(creation.manifestJSON))
                p(.class("field-note")) {
                    "GitHub creates the App on \(creation.ownerLabel), then returns its credentials to this server."
                }
                div(.class("toolbar toolbar--end")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Create App on GitHub" }
                }
            }
            details(.id("github-app-options")) {
                summary(.class("disclosure-summary")) {
                    span(.class("accordion-caret"), .ariaHidden) { Icon("i-chevron-right") }
                    "Owner and permissions"
                }
                optionsForm
            }
            .attributes(.custom(name: "open"), when: organizationOpen)
        }
    }

    private var optionsForm: some HTML {
        form(.method(.get), .action("/admin/github"), .class("form-stack")) {
            div(.class("field-stack")) {
                label(.for("github-org")) { "Organization" }
                input(
                    .id("github-org"), .class("form-input"), .type(.text), .name("org"), .value(organization),
                    .placeholder("uwaterloo-cs"))
            }
            AdminGitHubOption(
                name: "courseRepositories", checked: courseRepositories, label: "Allow course repositories",
                note: "Adds write access to repository administration and read access to organization members.")
            AdminGitHubOption(
                name: "pushEvents", checked: pushEvents, label: "Receive push events",
                note: "Shows staff the last push to each course repository.")
            AdminGitHubOption(
                name: "commitStatuses", checked: commitStatuses, label: "Post commit statuses",
                note: "Adds write access to commit statuses, so an assignment can post its public-test count.")
            div(.class("toolbar toolbar--end")) {
                button(.class("btn"), .type(.submit)) { "Apply" }
            }
        }
    }
}

/// The registered App's toolbar: open it on GitHub, or remove it here.
private struct AdminGitHubAppToolbar: HTML {
    let app: AdminGitHubAppDetails
    let csrfToken: String

    var body: some HTML {
        div(.class("toolbar")) {
            a(.class("btn action-btn"), .href(app.htmlURL), .target(.blank), .rel("noopener noreferrer")) {
                "Open on GitHub "
                Icon("i-external")
            }
            details(.class("add-section-details popup-anchor")) {
                summary(
                    .class("btn action-btn action-btn-icon summary-btn"), .title("More actions"),
                    .ariaLabel("More actions for the GitHub App")
                ) {
                    Icon("i-more")
                }
                div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                    form(
                        .method(.post), .action("/admin/github/delete"),
                        .custom(
                            name: "data-confirm",
                            value:
                                "Remove the GitHub App registration? Chickadee deletes the App credentials from this server and cannot restore them."
                        )
                    ) {
                        CSRFField(token: csrfToken)
                        button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                            Icon("i-trash")
                            span {
                                "Remove registration"
                                br()
                                span(.class("card-meta")) { "Deletes credentials here, not the App on GitHub" }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One term and its value, as a cell of the detail grid.
private struct AdminGitHubDetailCell<Value: HTML>: HTML {
    let term: String
    let value: Value

    init(term: String, @HTMLBuilder value: () -> Value) {
        self.term = term
        self.value = value()
    }

    var body: some HTML {
        div {
            dt { term }
            dd { value }
        }
    }
}

/// One manifest option: a checkbox and the note that says what it grants.
private struct AdminGitHubOption: HTML {
    let name: String
    let checked: Bool
    let label: String
    let note: String

    var body: some HTML {
        Elementary.label(.class("checkbox-row")) {
            input(.type(.checkbox), .name(name))
                .attributes(.checked, when: checked)
            label
        }
        p(.class("field-note field-note--muted")) { note }
    }
}
