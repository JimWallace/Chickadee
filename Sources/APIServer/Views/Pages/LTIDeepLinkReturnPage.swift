// APIServer/Views/Pages/LTIDeepLinkReturnPage.swift
//
// The deep-linking hand-back: a form that posts the signed response to the
// LMS return URL. Rendered in the LMS frame, so it has no site chrome.

import Elementary

struct LTIDeepLinkReturnPage: HTML {
    let page: PageRequestContext
    /// The platform's return URL; the route allows it as a form-action.
    let returnURL: String
    /// The signed LtiDeepLinkingResponse.
    let jwt: String

    var body: some HTML {
        BaseLayout(title: "Return to LMS", page: page, embedded: true) {
            h1 { "Return to LMS" }
            p(.class("section-intro")) {
                "Your assignment links are ready. Return to the LMS to finish adding them."
            }
            form(.method(.post), .action(returnURL), .class("form-stack")) {
                input(.type(.hidden), .name("JWT"), .value(jwt))
                div(.class("toolbar toolbar--end")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Return to LMS" }
                }
            }
        }
    }
}
