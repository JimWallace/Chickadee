// APIServer/Views/Pages/LTIDeepLinkBindPage.swift
//
// A deep-linking launch from an LMS course that is not linked yet, and
// POST /lti/deep-link/bind: link the LMS course before the content picker.
// Rendered in the LMS frame, so it has no site chrome and no session.

import Elementary

struct LTIDeepLinkBindPage: HTML {
    let page: PageRequestContext
    /// The signed bind token the form carries in place of a session.
    let token: String
    let contextTitle: String
    let courses: [LTIBindCourseOption]
    let error: String?

    var body: some HTML {
        BaseLayout(title: "Link LMS course", page: page, embedded: true) {
            h1 { "Link LMS course" }
            p(.class("section-intro")) {
                "Choose the Chickadee course for "
                strong { contextTitle }
                ". Launches and content added from this LMS course then go to it."
            }
            if let error {
                div(.class("form-error"), .role("alert")) { error }
            }
            if courses.isEmpty {
                p(.class("empty")) { "No unlinked Chickadee course is available to you." }
                p(.class("section-note")) {
                    "Ask an administrator to create the course, or to add you as its instructor, "
                        + "then open the LMS content picker again."
                }
            } else {
                form(.method(.post), .action("/lti/deep-link/bind"), .class("form-stack")) {
                    input(.type(.hidden), .name("token"), .value(token))
                    LTICourseSelect(id: "lti-dl-bind-course", courses: courses)
                    div(.class("toolbar toolbar--end")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Link and continue" }
                    }
                }
            }
        }
    }
}
