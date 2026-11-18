// APIServer/Views/Pages/AdminDeploymentPage.swift
//
// GET /admin/deployment: what runs, what waits for approval, the deploy mode,
// pause, and the deploy history (docs/release-gate.md). Every action is a
// request to the deploy daemon, which decides; rollback stays a host action.

import Elementary

struct AdminDeploymentPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let view: AdminDeploymentView

    var body: some HTML {
        BaseLayout(title: "Deployment", page: page, flash: flash) {
            AdminTabs(active: .deployment, page: page)
            DeploymentRunningSection(view: view, csrfToken: page.csrfToken)
            if let held = view.held {
                DeploymentHeldSection(held: held, canSend: view.canSendRequests, csrfToken: page.csrfToken)
            }
            DeploymentModeSection(view: view, csrfToken: page.csrfToken)
            DeploymentHistorySection(history: view.history)
        }
    }
}

/// What runs: the deployed version, the mode, pause, and the daemon's state.
private struct DeploymentRunningSection: HTML {
    let view: AdminDeploymentView
    let csrfToken: String

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    "Deployment "
                    if !view.available {
                        span(.class("tier tier-closed")) { "No daemon" }
                    } else if view.paused {
                        span(.class("tier")) { "Paused" }
                    } else {
                        span(.class("tier")) { "Running" }
                    }
                }
                if view.available && view.canSendRequests {
                    form(
                        .method(.post), .action(view.paused ? "/admin/deployment/resume" : "/admin/deployment/pause"),
                        .class("form-flush")
                    ) {
                        CSRFField(token: csrfToken)
                        button(.class("btn action-btn"), .type(.submit)) { view.paused ? "Resume" : "Pause" }
                    }
                }
            }
            if !view.available {
                FlashBanner(.warning) {
                    "No deploy status in "
                    code { view.stateDirectory }
                    ": the deploy daemon is not running here, or its folder is not mounted."
                }
            } else if !view.canSendRequests {
                FlashBanner(.warning) {
                    "The requests folder is not mounted, so this page can show the deploy state but not change it."
                }
            }
            if view.available {
                div(.class("card section-gap")) {
                    dl(.class("detail-grid")) {
                        dt { "Running" }
                        dd { code { view.deployedVersion ?? "unknown" } }
                        dt { "Mode" }
                        dd { view.mode.label }
                        dt { "Channel (host)" }
                        dd { code { view.channel } }
                        dt { "Daemon" }
                        dd {
                            code { view.state ?? "unknown" }
                            if let detail = view.detail, !detail.isEmpty { " · \(detail)" }
                        }
                        dt { "Last update" }
                        dd {
                            if let updatedAt = view.updatedAt {
                                span(.class("js-relative-time"), .data("iso", value: updatedAt)) { updatedAt }
                            } else {
                                "Unknown"
                            }
                        }
                        if view.waitingRequests > 0 {
                            dt { "Requests" }
                            dd { "\(view.waitingRequests) waiting" }
                        }
                        dt { "Rollback (host)" }
                        dd {
                            code { #"echo '{"command":"rollback"}' | sudo tee /var/lib/chickadee-deploy/command.json"# }
                        }
                    }
                }
            }
        }
    }
}

/// What waits: the held release, its notes, and the approval form.
private struct DeploymentHeldSection: HTML {
    let held: AdminDeploymentView.Held
    let canSend: Bool
    let csrfToken: String

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    "Waiting for approval "
                    code { held.version }
                    " "
                    if held.isApproved {
                        span(.class("tier")) { "Approved" }
                    }
                    if !held.contractPullRequests.isEmpty {
                        span(.class("tier tier-preview")) { "Contract change" }
                    }
                }
            }
            if held.isApproved {
                p(.class("section-intro")) { "Deploys on the daemon’s next poll." }
            } else if canSend {
                form(.method(.post), .action("/admin/deployment/approve"), .class("form card section-gap")) {
                    CSRFField(token: csrfToken)
                    label(.class("form-label"), .for("deploy-approve-version")) {
                        "Type \(held.version) to approve it"
                        input(
                            .id("deploy-approve-version"), .class("form-input"), .type(.text), .name("version"),
                            .required, .autocomplete(.off), .placeholder(held.version))
                        span(.class("field-note field-note--muted")) {
                            "It deploys on the daemon’s next poll, unless paused."
                        }
                    }
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Approve \(held.version)" }
                    }
                }
            }
            if !held.contractPullRequests.isEmpty {
                h3 { "Contract changes" }
                ul {
                    for pull in held.contractPullRequests {
                        li {
                            span(.class("tier tier-preview")) { "Contract change" }
                            " "
                            if let url = pull.url {
                                a(.href(url)) { "#\(pull.number)" }
                            } else {
                                "#\(pull.number)"
                            }
                            " \(pull.title)"
                        }
                    }
                }
            }
            if !held.hasNotes {
                p(.class("text-muted")) { "The daemon has not written the release notes for this release yet." }
            }
            for release in held.releases {
                DeploymentReleaseNotes(release: release)
            }
        }
    }
}

/// One release's notes, with every contract change flagged.
private struct DeploymentReleaseNotes: HTML {
    let release: AdminDeploymentView.ReleaseNotes

    var body: some HTML {
        h3 {
            if let url = release.url {
                a(.href(url)) { release.name }
            } else {
                release.name
            }
        }
        if release.entries.isEmpty {
            p(.class("text-muted")) { "No notes." }
        } else {
            ul {
                for entry in release.entries {
                    if entry.isHeading {
                        li { strong { entry.text } }
                    } else {
                        li {
                            if entry.isContractChange {
                                span(.class("tier tier-preview")) { "Contract change" }
                                " "
                            }
                            entry.text
                        }
                    }
                }
            }
        }
    }
}

/// The three modes, changeable in both directions: one choice of three, so a
/// radio group with one Save button, not a row of buttons. Saving asks first,
/// because the daemon acts on the new mode at its next poll. Where no request
/// can be sent, the same radios show, disabled, so the other modes stay
/// readable.
private struct DeploymentModeSection: HTML {
    let view: AdminDeploymentView
    let csrfToken: String

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "Mode" }
            if view.available && view.canSendRequests {
                form(
                    .method(.post), .action("/admin/deployment/mode"), .class("form-stack"),
                    .data("confirm", value: "Save the deploy mode? The deployer follows it at its next poll.")
                ) {
                    CSRFField(token: csrfToken)
                    DeploymentModeChoices(current: view.mode, isEnabled: true)
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Save mode" }
                    }
                }
            } else {
                DeploymentModeChoices(current: view.mode, isEnabled: false)
            }
        }
    }
}

/// The three modes as radios, the current one checked. The `h2` above names
/// the group, so its legend is for screen readers only. Disabled, it still
/// shows every mode and which one is in force.
private struct DeploymentModeChoices: HTML {
    let current: DeployMode
    let isEnabled: Bool

    var body: some HTML {
        fieldset(.class("fieldset-plain")) {
            legend(.class("visually-hidden")) { "Deploy mode" }
            div(.class("checkbox-list")) {
                for mode in DeployMode.allCases {
                    DeploymentModeOption(mode: mode, isCurrent: mode == current)
                }
            }
        }
        .attributes(.disabled, when: !isEnabled)
    }
}

/// One mode as a radio: its name, with "(default)" on the daemon's default,
/// and its one-line summary under it.
private struct DeploymentModeOption: HTML {
    let mode: DeployMode
    let isCurrent: Bool

    var body: some HTML {
        label(.class("checkbox-row checkbox-row--described")) {
            input(.type(.radio), .name("mode"), .value(mode.rawValue))
                .attributes(.checked, when: isCurrent)
            span {
                strong { mode == .daemonDefault ? "\(mode.label) (default)" : mode.label }
                span(.class("field-note field-note--muted")) { mode.summary }
            }
        }
    }
}

/// The last deploys, rollbacks and requests, newest first.
private struct DeploymentHistorySection: HTML {
    let history: [AdminDeploymentView.HistoryRow]

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "History" }
            if history.isEmpty {
                p(.class("empty")) { "No deploy history." }
            } else {
                table(.class("results-table section-items section-items--manage")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-count"))
                        col(.class("section-items-seen col-hide-phone"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Event" }
                            th(.custom(name: "scope", value: "col")) { "Detail" }
                            th(.custom(name: "scope", value: "col")) { "Result" }
                            th(.custom(name: "scope", value: "col")) { "When" }
                        }
                    }
                    tbody {
                        for row in history {
                            DeploymentHistoryRow(row: row)
                        }
                    }
                }
            }
        }
    }
}

private struct DeploymentHistoryRow: HTML {
    let row: AdminDeploymentView.HistoryRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: row.isFailure ? "alert" : "ok")) { Icon("i-server") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    row.action
                    if !row.version.isEmpty {
                        " "
                        code { row.version }
                    }
                    if let user = row.user {
                        " · \(user)"
                    }
                }
                if !row.detail.isEmpty {
                    div(.class("item-details")) { row.detail }
                }
            }
            td {
                span(.class(row.isFailure ? "tier tier-danger" : "tier")) { row.result }
            }
            td(.class("col-hide-phone js-relative-time"), .data("iso", value: row.ts)) { row.ts }
        }
    }
}
