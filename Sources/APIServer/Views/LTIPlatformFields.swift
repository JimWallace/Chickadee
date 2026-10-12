// APIServer/Views/LTIPlatformFields.swift
//
// The fields of one LTI platform registration (docs/lti-1-3.md), shared by
// the add form and each edit form on the admin LTI page. Each copy takes its
// own id prefix, so every copy on the page has unique ids. A validation error
// shows here, beside the form it belongs to, rather than at the top of the
// page, which can be a whole table away.

import Elementary

struct LTIPlatformFields: HTML, Sendable {
    let idPrefix: String
    let form: LTIPlatformForm
    var error: String?

    var body: some HTML {
        if let error {
            div(.class("form-error"), .role("alert")) { error }
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-name")) { "Name" }
            input(
                .id("\(idPrefix)-name"), .class("form-input"), .type(.text), .name("displayName"),
                .value(form.displayName), .required, .placeholder("UW LEARN"))
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-issuer")) { "Issuer" }
            input(
                .id("\(idPrefix)-issuer"), .class("form-input"), .type(.url), .name("issuer"),
                .value(form.issuer), .required, .placeholder("https://learn.example.edu"))
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-client")) { "Client ID" }
            input(
                .id("\(idPrefix)-client"), .class("form-input"), .type(.text), .name("clientID"),
                .value(form.clientID), .required)
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-deployments")) { "Deployment IDs" }
            textarea(
                .id("\(idPrefix)-deployments"), .class("form-input textarea-mono"), .name("deploymentIDs"),
                .rows(3), .required
            ) {
                form.deploymentIDs
            }
            p(.class("field-note")) { "One per line." }
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-auth")) { "OIDC authorization URL" }
            input(
                .id("\(idPrefix)-auth"), .class("form-input"), .type(.url), .name("authLoginURL"),
                .value(form.authLoginURL), .required)
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-token")) { "Access token URL" }
            input(
                .id("\(idPrefix)-token"), .class("form-input"), .type(.url), .name("accessTokenURL"),
                .value(form.accessTokenURL), .required)
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-audience")) { "Token audience" }
            input(
                .id("\(idPrefix)-audience"), .class("form-input"), .type(.text), .name("tokenAudience"),
                .value(form.tokenAudience ?? ""), .custom(name: "aria-describedby", value: "\(idPrefix)-audience-note"))
            p(.class("field-note"), .id("\(idPrefix)-audience-note")) {
                "Leave blank to use the access token URL; Brightspace calls it OAuth2 Audience."
            }
        }
        div(.class("field-stack")) {
            label(.for("\(idPrefix)-jwks")) { "Key set URL" }
            input(
                .id("\(idPrefix)-jwks"), .class("form-input"), .type(.url), .name("jwksURL"),
                .value(form.jwksURL), .required)
        }
        div(.class("field-stack")) {
            label(.class("checkbox-row")) {
                input(
                    .type(.checkbox), .name("trustUsername"), .value("true"),
                    .custom(name: "aria-describedby", value: "\(idPrefix)-trust-note")
                )
                .attributes(.checked, when: form.trustUsername == true)
                "Trust this platform's username"
            }
            p(.class("field-note"), .id("\(idPrefix)-trust-note")) {
                "Links a launch to the account named in its "
                code { "username" }
                " custom parameter."
            }
        }
    }
}
