// APIServer/Views/Pages/ConnectedAgentsPage.swift
//
// GET /agents: the OAuth grants agents hold on a person's behalf, with a
// revoke action. An admin sees every grant and its owner.

import Elementary

struct ConnectedAgentsPage: HTML {
    let page: PageRequestContext
    let isAdmin: Bool
    let rows: [AgentGrantRow]

    var body: some HTML {
        BaseLayout(title: "Connected agents", page: page) {
            section(.class("page-section")) {
                h1(.class("agents-heading")) { "Connected agents" }
                p(.class("section-intro")) {
                    "AI agents authorized to author course content on \(isAdmin ? "a user's" : "your") behalf over the Model Context Protocol. Revoking stops the agent immediately; any access token it holds lapses within minutes. "
                    NewTabLink(
                        href: "https://github.com/JimWallace/Chickadee/blob/main/docs/ai-assisted-feedback.md",
                        text: "What a feedback grant can read "
                    )
                }
                div(.class("table-scroll")) {
                    table(.class("results-table")) {
                        thead {
                            tr {
                                th { "Agent" }
                                if isAdmin { th { "Authorized by" } }
                                th { "Scopes" }
                                th(.class("time")) { "Authorized" }
                                th(.class("time")) { "Last used" }
                                th(.class("time")) { "Expires" }
                                th { "Status" }
                            }
                        }
                        tbody {
                            for row in rows {
                                ConnectedAgentRow(row: row, isAdmin: isAdmin, csrfToken: page.csrfToken)
                            }
                            if rows.isEmpty {
                                tr {
                                    td(.custom(name: "colspan", value: isAdmin ? "7" : "6"), .class("text-muted")) {
                                        "No connected agents."
                                    }
                                }
                            }
                        }
                    }
                }
            }
            PageStyle(
                """
                .agents-heading { margin-top: 0; }
                .agents-revoke-form { display: inline; }
                """
            )
        }
    }
}

/// One grant, with its revoke action while it is not revoked.
struct ConnectedAgentRow: HTML {
    let row: AgentGrantRow
    let isAdmin: Bool
    let csrfToken: String

    var body: some HTML {
        tr {
            td { row.agentName }
            if isAdmin { td { code { row.owner ?? "" } } }
            td { code { row.scope } }
            td(.class("time js-relative-time"), .custom(name: "data-iso", value: row.createdAt)) { row.createdAt }
            if let lastUsedAt = row.lastUsedAt {
                td(.class("time js-relative-time"), .custom(name: "data-iso", value: lastUsedAt)) { lastUsedAt }
            } else {
                td(.class("time")) { "—" }
            }
            td(.class("time js-relative-time"), .custom(name: "data-iso", value: row.expiresAt)) { row.expiresAt }
            td {
                if row.revoked {
                    span(.class("text-muted")) { "Revoked" }
                } else {
                    form(.method(.post), .action("/agents/\(row.id)/revoke"), .class("agents-revoke-form")) {
                        CSRFField(token: csrfToken)
                        button(
                            .class("btn action-btn action-danger"), .type(.submit),
                            .custom(name: "data-confirm", value: "Revoke this agent? It will lose access immediately.")
                        ) { "Revoke" }
                    }
                }
            }
        }
    }
}
