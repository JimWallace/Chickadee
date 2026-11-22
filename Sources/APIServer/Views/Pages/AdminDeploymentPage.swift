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
                DeploymentHeldSection(
                    held: held, kind: .held, canSend: view.canSendRequests, csrfToken: page.csrfToken,
                    upgradeFailure: view.databaseUpgradeFailure)
            }
            if let prerelease = view.prerelease {
                DeploymentHeldSection(
                    held: prerelease, kind: .prerelease, canSend: view.canSendRequests, csrfToken: page.csrfToken,
                    upgradeFailure: nil)
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
            // With a held release the alert goes on its card instead.
            if view.held == nil, let failure = view.databaseUpgradeFailure {
                DeploymentUpgradeFailureBanner(failure: failure)
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
                        if let major = view.dbRunningMajor {
                            dt { "Database" }
                            dd {
                                "PostgreSQL \(major)"
                                if let state = view.dbUpgradeState {
                                    " · upgrade "
                                    code { state }
                                    if let detail = view.dbUpgradeDetail { " · \(detail)" }
                                }
                            }
                        }
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

/// What waits: the held release, its notes, and the approval form. The same
/// card offers the newest pre-release (Coming next), which production deploys
/// only when an admin approves it here: no mode deploys a pre-release.
private struct DeploymentHeldSection: HTML {
    enum Kind {
        case held, prerelease
    }

    let held: AdminDeploymentView.Held
    let kind: Kind
    let canSend: Bool
    let csrfToken: String
    /// The last database upgrade failed: the alert shows on this card.
    let upgradeFailure: AdminDeploymentView.DatabaseUpgradeFailure?

    private var inputID: String { kind == .held ? "deploy-approve-version" : "deploy-approve-prerelease" }

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    kind == .held ? "Waiting for approval " : "Coming next "
                    code { held.version }
                    " "
                    if kind == .prerelease {
                        span(.class("tier")) { "Pre-release" }
                    }
                    if held.isApproved {
                        span(.class("tier")) { "Approved" }
                    }
                    if !held.contractPullRequests.isEmpty {
                        span(.class("tier tier-preview")) { "Contract change" }
                    }
                }
            }
            if let upgradeFailure {
                DeploymentUpgradeFailureBanner(failure: upgradeFailure)
            }
            if let upgrade = held.databaseUpgrade {
                FlashBanner(.warning) {
                    "This release upgrades PostgreSQL from \(upgrade.fromMajor) to \(upgrade.toMajor), "
                        + "and the app is down for a few minutes."
                }
            }
            if kind == .prerelease && !held.isApproved {
                p(.class("section-intro")) {
                    "Runs on the dev server; deploys here only when approved."
                }
            }
            if held.isApproved {
                p(.class("section-intro")) {
                    held.databaseUpgrade == nil
                        ? "Deploys on the daemon’s next poll."
                        : "Upgrades the database, then deploys on the daemon’s next poll."
                }
            } else if canSend {
                form(
                    .method(.post), .action("/admin/deployment/approve"),
                    .class("form form--wide card card--padded section-gap")
                ) {
                    CSRFField(token: csrfToken)
                    label(.class("form-label"), .for(inputID)) {
                        "Type \(held.version) to approve it"
                        input(
                            .id(inputID), .class("form-input"), .type(.text), .name("version"),
                            .required, .autocomplete(.off), .placeholder(held.version))
                        span(.class("field-note field-note--muted")) {
                            held.databaseUpgrade == nil
                                ? "It deploys on the daemon’s next poll, unless paused."
                                : "It upgrades the database, then deploys on the daemon’s next poll, unless paused."
                        }
                    }
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Approve \(held.version)" }
                    }
                }
            }
            if !held.contractPullRequests.isEmpty {
                div(.class("card card--padded section-gap")) {
                    h3 { "Contract changes" }
                    ul {
                        for pull in held.contractPullRequests {
                            li {
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

/// The alert for a database upgrade that failed or rolled back. The Database
/// row on the running card carries the detail and the log path.
private struct DeploymentUpgradeFailureBanner: HTML {
    let failure: AdminDeploymentView.DatabaseUpgradeFailure

    var body: some HTML {
        let target = failure.toMajor.map { " to PostgreSQL \($0)" } ?? ""
        FlashBanner(.error, role: "alert") {
            failure.rolledBack
                ? "The database upgrade\(target) failed and was rolled back; the release was not deployed."
                : "The database upgrade\(target) failed; the release was not deployed."
        }
    }
}

/// One release's notes as a card: its name, then each `### Changed`-style
/// heading above its own list, with every contract change flagged.
private struct DeploymentReleaseNotes: HTML {
    let release: AdminDeploymentView.ReleaseNotes

    var body: some HTML {
        div(.class("card card--padded section-gap")) {
            h3 {
                if let url = release.url {
                    a(.href(url)) { release.name }
                } else {
                    release.name
                }
            }
            let sections = DeployReleaseNotes.sections(of: release.entries)
            if sections.isEmpty {
                p(.class("text-muted")) { "No notes." }
            }
            for section in sections {
                if let heading = section.heading {
                    h4 { heading }
                }
                ul {
                    for entry in section.items {
                        li {
                            if entry.isContractChange {
                                span(.class("tier tier-preview")) { "Contract change" }
                                " "
                            }
                            // Changelog entries mark code with backticks; an
                            // odd-numbered part is between a pair of them. An
                            // unmatched backtick leaves the entry as plain text.
                            let parts = entry.text.split(separator: "`", omittingEmptySubsequences: false)
                            if parts.count.isMultiple(of: 2) {
                                entry.text
                            } else {
                                for (index, part) in parts.enumerated() {
                                    if index.isMultiple(of: 2) {
                                        String(part)
                                    } else {
                                        code { String(part) }
                                    }
                                }
                            }
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
                    DeploymentModeChoices(current: view.pendingMode ?? view.mode, isEnabled: true)
                    if let pending = view.pendingMode {
                        p(.class("field-note field-note--muted")) {
                            "\(pending.label) requested; the deployer applies it at its next poll."
                        }
                    }
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
                        col(.class("section-items-count section-items-count--wide"))
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
            td(.class("item-status item-grade")) {
                span(.class(row.isFailure ? "tier tier-danger" : "tier")) { row.result }
            }
            td(.class("col-hide-phone js-relative-time"), .data("iso", value: row.ts)) { row.ts }
        }
    }
}
