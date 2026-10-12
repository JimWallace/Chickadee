// APIServer/Views/Pages/RegisterPage.swift
//
// GET /register: local account creation. The auth-box archetype's exemplar
// (docs/ui-design.md).

import Elementary

struct RegisterPage: HTML {
    let page: PageRequestContext
    /// The `?error=` code from a refused registration.
    let error: String?

    var body: some HTML {
        BaseLayout(title: "Register", page: page) {
            div(.class("auth-box")) {
                h1 { "Create an account" }
                if let message = error.flatMap(Self.message(for:)) {
                    div(.class("error-box"), .role("alert")) { p { message } }
                }
                form(.class("form"), .method(.post), .action("/register")) {
                    CSRFField(token: page.csrfToken)
                    label(.class("form-label")) {
                        "Username"
                        input(
                            .class("form-input"), .type(.text), .name("username"), .autocomplete("username"),
                            .autofocus, .required, .minlength(3))
                    }
                    label(.class("form-label")) {
                        "Password"
                        input(
                            .class("form-input"), .type(.password), .name("password"),
                            .autocomplete("new-password"), .required, .minlength(8))
                        span(.class("card-meta")) { "At least 8 characters" }
                    }
                    button(.class("btn btn-primary"), .type(.submit)) { "Create account" }
                }
                p(.class("auth-alt")) {
                    "Already have an account? "
                    a(.href("/login")) { "Log in" }
                }
            }
        }
    }

    /// The sentence for each `?error=` code the registration route sends. An
    /// unknown code shows nothing.
    static func message(for error: String) -> String? {
        switch error {
        case "taken": "That username is already taken."
        case "username_short": "Username must be at least 3 characters."
        case "password_short": "Password must be at least 8 characters."
        default: nil
        }
    }
}
