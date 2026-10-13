// APIServer/Views/Pages/LoginPage.swift
//
// GET /login: the auth-box sign-in page, local and SSO.

import Elementary

struct LoginPage: HTML {
    let page: PageRequestContext
    /// The `?error=` code from a failed sign-in.
    let error: String?
    /// True after `/logout`; the notice shows only when there is no error.
    let loggedOut: Bool
    let showLocalLogin: Bool
    let showRegisterLink: Bool
    let showSSOLogin: Bool

    var body: some HTML {
        BaseLayout(title: "Log in", page: page) {
            div(.class("auth-box")) {
                img(
                    .class("auth-logo"), .src(page.asset("/images/chickadee-welcome.png")), .alt(""),
                    .width(72), .height(72))
                h1 { "Log in to Chickadee" }
                if loggedOut && error == nil {
                    div(.class("notice-box")) {
                        p { "You have been signed out." }
                    }
                }
                if let error {
                    div(.class("error-box")) {
                        p { Self.message(for: error) }
                    }
                }
                if showSSOLogin {
                    div(.class("form")) {
                        a(.class("btn btn-primary btn--center"), .href("/auth/sso/start")) { "Log in with UWaterloo" }
                        p(.class("field-note")) { "Use your WatIAM username and password." }
                    }
                }
                if showLocalLogin {
                    localForm
                }
                if showRegisterLink {
                    p(.class("auth-alt")) {
                        "No account? "
                        a(.href("/register")) { "Register" }
                    }
                }
            }
        }
    }

    private var localForm: some HTML {
        form(.class("form"), .method(.post), .action("/login")) {
            CSRFField(token: page.csrfToken)
            label(.class("form-label")) {
                "Username"
                input(
                    .class("form-input"), .type(.text), .name("username"), .autocomplete("username"),
                    .autofocus, .required)
            }
            label(.class("form-label")) {
                "Password"
                input(
                    .class("form-input"), .type(.password), .name("password"),
                    .autocomplete("current-password"), .required)
            }
            button(.class("btn btn-primary"), .type(.submit)) { "Log in" }
        }
    }

    /// The sentence for each `?error=` code the sign-in routes send. An unknown
    /// code gets the generic sentence, never the code itself.
    static func message(for error: String) -> String {
        switch error {
        case "invalid": "Invalid username or password."
        case "locked": "Too many failed sign-in attempts. Please try again in a few minutes."
        case "timeout": "You were signed out after a period of inactivity. Please log in again."
        case "sso_denied": "UWaterloo sign-in was canceled or denied."
        case "sso_not_configured": "UWaterloo sign-in is not configured on this server."
        case "sso_failed": "UWaterloo sign-in failed. Please try again."
        default: "Sign-in failed. Please try again."
        }
    }
}
