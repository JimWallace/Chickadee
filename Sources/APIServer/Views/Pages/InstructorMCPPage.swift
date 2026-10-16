// APIServer/Views/Pages/InstructorMCPPage.swift
//
// GET /instructor/mcp: the AI agents tab. What an agent that course staff
// connect can reach in the active course (AI-assisted feedback and the
// viewer's attestation), and the course's authoring voice for connected
// agents, editable by the course's instructors.

import Elementary

struct InstructorMCPPage: HTML {
    let page: PageRequestContext
    let flash: FlashMessages
    let hasActiveCourse: Bool
    let courseCode: String
    /// The course's effective voice guide: its own text when customized, else
    /// Chickadee's default, as the textarea's value.
    let guidanceText: String
    /// Character count of `guidanceText`, shown against `maxLength`.
    let guidanceLength: Int
    /// True when `guidanceText` is course-authored rather than the default.
    let isCustomized: Bool
    /// `canEdit && isCustomized`: the Reset menu shows.
    let showResetButton: Bool
    /// A noun phrase that names where the current text comes from.
    let sourceNote: String
    let maxLength: Int
    /// True when the viewer may save: a per-course instructor or an admin, and
    /// the course is not archived.
    let canEdit: Bool
    /// Why the panel is read-only; nil when `canEdit`.
    let readOnlyNote: String?
    /// True when the MCP server is not mounted on this deployment.
    let mcpDisabled: Bool
    /// The access section: content, AI-assisted feedback and the attestation.
    let agentAccess: AgentAccessFacts

    var body: some HTML {
        BaseLayout(title: "AI agents", page: page, flash: flash) {
            InstructorTabs(active: .mcp)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its AI agents." }
                }
            } else {
                accessSection
                voiceSection
            }
        }
    }

    private var accessSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Agent access" }
                a(.class("btn action-btn"), .href("/agents")) { "Connected agents" }
            }
            p(.class("section-intro")) { "What an agent that course staff connect can reach in \(courseCode)." }
            dl(.class("detail-grid")) {
                dt { "Feedback on written answers" }
                dd { OnOffTier(isOn: agentAccess.feedbackOn, on: "On", off: "Off") }
                if agentAccess.feedbackOn {
                    dt { "Your account attestation" }
                    dd { attestation }
                }
            }
            if agentAccess.canAttest {
                p(.class("field-note")) {
                    "The attestation says you connect only your UW-licensed AI account for feedback. "
                    NewTabLink(
                        href:
                            "https://github.com/JimWallace/Chickadee/blob/main/docs/ai-assisted-feedback.md#the-ai-agents-tab",
                        text: "Why "
                    )
                }
            }
            if agentAccess.feedbackOn {
                if agentAccess.feedbackAssignments.isEmpty {
                    p(.class("empty")) { "No assignment has AI-assisted feedback on yet." }
                    p(.class("section-note")) { "An instructor turns it on in each assignment's Student Options." }
                } else {
                    feedbackTable
                }
            }
        }
    }

    @HTMLBuilder private var attestation: some HTML {
        if let attestedAtISO = agentAccess.attestedAtISO {
            "Recorded "
            code { attestedAtISO }
            attestationForm(action: "withdraw") {
                button(.class("btn action-btn"), .type(.submit)) { "Withdraw" }
            }
        } else if agentAccess.canAttest {
            span(.class("tier tier-closed")) { "Not recorded" }
            attestationForm(action: "record") {
                button(.class("btn btn-primary"), .type(.submit)) { "Record attestation" }
            }
        } else {
            span(.class("tier tier-closed")) { "Not recorded" }
        }
    }

    private func attestationForm(action: String, @HTMLBuilder button: () -> some HTML) -> some HTML {
        form(.method(.post), .action("/instructor/mcp/attestation"), .class("form-flush")) {
            CSRFField(token: page.csrfToken)
            input(.type(.hidden), .name("action"), .value(action))
            button()
        }
    }

    private var feedbackTable: some HTML {
        table(.class("results-table section-items")) {
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Type" }
                    th(.custom(name: "scope", value: "col")) { "Assignment" }
                    th(.custom(name: "scope", value: "col")) { "Drafts to review" }
                }
            }
            tbody {
                for row in agentAccess.feedbackAssignments {
                    tr {
                        td(.class("item-tile-cell")) {
                            span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-calendar-check") }
                        }
                        td(.class("item-main")) { div(.class("item-title")) { a(.href(row.reviewURL)) { row.title } } }
                        td(.class("item-status")) { span(.class("chip")) { "\(row.draftCount) to review" } }
                    }
                }
            }
        }
    }

    private var voiceSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    "Authoring voice "
                    OnOffTier(isOn: isCustomized, on: "Customized", off: "Default")
                }
                if canEdit {
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary"), .type(.submit), .form("mcp-guide")) { "Save" }
                        if showResetButton {
                            resetMenu
                        }
                    }
                }
            }
            p(.class("section-intro")) {
                "What connected agents follow when they write assignment prose for \(courseCode)."
            }
            div(.class("editor-split")) {
                form(.method(.post), .action("/instructor/mcp"), .id("mcp-guide"), .class("form-stack")) {
                    CSRFField(token: page.csrfToken)
                    label(.class("form-label")) {
                        "Guide text"
                        textarea(
                            .class("form-input textarea-mono"), .name("instructions"), .rows(24),
                            .maxlength(maxLength)
                        ) { guidanceText }
                        .attributes(.disabled, when: !canEdit)
                        span(.class("field-note field-note--muted")) {
                            "Plain text; an empty box restores the Chickadee default."
                        }
                    }
                }
                aside(.class("card")) {
                    dl(.class("detail-grid")) {
                        dt { "Source" }
                        dd { sourceNote }
                        dt { "MCP server" }
                        dd { OnOffTier(isOn: !mcpDisabled, on: "Enabled", off: "Disabled") }
                        dt { "Length" }
                        dd { "\(guidanceLength) / \(maxLength)" }
                    }
                    if mcpDisabled {
                        p(.class("section-note")) {
                            "The MCP server is disabled on this deployment, so no agent can connect yet."
                        }
                    }
                    if let readOnlyNote {
                        p(.class("section-note")) { readOnlyNote }
                    }
                }
            }
        }
    }

    private var resetMenu: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(
                .class("btn action-btn action-btn-icon summary-btn"), .title("More actions"),
                .ariaLabel("More actions for the authoring voice")
            ) { Icon("i-more") }
            div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                button(
                    .class("row-menu-item"), .type(.submit), .form("mcp-guide"), .name("action"),
                    .custom(name: "value", value: "reset"), .role("menuitem")
                ) { "Reset to Chickadee default" }
            }
        }
    }
}

/// An open tier when on, a closed tier when off.
private struct OnOffTier: HTML {
    let isOn: Bool
    let on: String
    let off: String

    var body: some HTML {
        if isOn {
            span(.class("tier tier-open")) { on }
        } else {
            span(.class("tier tier-closed")) { off }
        }
    }
}
