// APIServer/Views/Pages/OAuthConsentPage.swift
//
// GET /oauth/authorize: the MCP agent consent screen, an auth-box card. The
// route relaxes the CSP form-action to the client's redirect origin.

import Elementary

struct OAuthConsentPage: HTML {
    let page: PageRequestContext
    let clientName: String
    let scopeLabels: [String]
    /// Host portion of the redirect URI, shown prominently so the human can spot
    /// an unexpected destination (DCR client names are self-asserted).
    let redirectHost: String
    /// True when the user has never approved this client — drives a warning.
    let firstTimeApproval: Bool
    let notPermitted: Bool
    /// Role label for the not-permitted message ("instructors and admins" for the
    /// content surface, "admins" for admin diagnostics).
    let permittedRoleLabel: String
    /// What the agent would be authorized to do, for the not-permitted message
    /// ("author course content" vs "read server diagnostics").
    let purposeLabel: String
    /// Single-use consent token embedded in the form; nil for the not-permitted
    /// view (no submittable form is shown).
    let requestToken: String?
    /// True when the grant includes `feedback:read`: the consent note must not
    /// say the agent cannot reach student data (docs/ai-assisted-feedback.md).
    let readsStudentAnswers: Bool

    var body: some HTML {
        BaseLayout(title: "Authorize agent", page: page) {
            div(.class("auth-box")) {
                h1 { "Authorize access" }
                if notPermitted {
                    div(.class("error-box")) {
                        p {
                            "You are signed in, but only "
                            strong { permittedRoleLabel }
                            " may authorize an agent to \(purposeLabel). Ask \(permittedRoleLabel) to complete this connection."
                        }
                    }
                } else {
                    consent
                }
            }
        }
    }

    @HTMLBuilder private var consent: some HTML {
        p(.class("section-gap")) {
            strong { clientName }
            " wants to act on your behalf over the Model Context Protocol. It will be able to:"
        }
        ul(.class("consent-scope-list")) {
            for label in scopeLabels {
                li { label }
            }
        }
        p(.class("section-gap fine-print")) {
            "After you authorize, you will be redirected to "
            strong { redirectHost }
            ". Only continue if you recognize this destination."
        }
        if firstTimeApproval {
            div(.class("error-box")) {
                p {
                    "⚠️ You have "
                    strong { "not approved this app before" }
                    ". Any app can register itself and choose its own name — authorize it only if you trust "
                    strong { redirectHost }
                    "."
                }
            }
        }
        p(.class("consent-note")) {
            "Actions taken by the agent are recorded as you, attributed to "
            strong { clientName }
            ". "
            if readsStudentAnswers {
                "It can read students' written answers, without names, only in assignments where AI-assisted feedback is on, and it cannot access grades or enrolment."
            } else {
                "It cannot access student data, grades, enrolment, or submissions."
            }
            " You can revoke access later."
        }
        form(.class("form"), .method(.post), .action("/oauth/authorize")) {
            input(.type(.hidden), .name("request_token"), .value(requestToken ?? ""))
            div(.class("toolbar")) {
                button(
                    .class("btn btn-primary"), .type(.submit), .name("decision"),
                    .custom(name: "value", value: "authorize")
                ) {
                    "Authorize"
                }
                button(.class("btn"), .type(.submit), .name("decision"), .custom(name: "value", value: "deny")) {
                    "Deny"
                }
            }
        }
    }
}
