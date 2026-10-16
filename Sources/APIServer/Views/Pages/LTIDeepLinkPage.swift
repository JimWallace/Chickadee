// APIServer/Views/Pages/LTIDeepLinkPage.swift
//
// The deep-linking content picker: course staff choose assignments to add to
// the LMS. Rendered in the LMS frame, so it has no site chrome and no
// session; the ticket stands in for both.

import Elementary

struct LTIDeepLinkPage: HTML {
    let page: PageRequestContext
    let ticket: String
    let courseCode: String
    /// Checkboxes when the LMS accepts several items, radios otherwise.
    let acceptMultiple: Bool
    let assignments: [LTIDeepLinkOption]
    let error: String?

    var body: some HTML {
        BaseLayout(title: "Add to LMS", page: page, embedded: true) {
            h1 { "Add to LMS" }
            p(.class("section-intro")) {
                "Choose what to add from \(courseCode). Each choice becomes a link that opens it in Chickadee."
            }
            if let error {
                div(.class("form-error"), .role("alert")) { error }
            }
            if assignments.isEmpty {
                p(.class("empty")) { "This course has no assignments yet." }
                p(.class("section-note")) {
                    NewTabLink(href: "/instructor/new", text: "Create an assignment ")
                    ", then open the LMS content picker again."
                }
            } else {
                form(.method(.post), .action("/lti/deep-link"), .class("form-stack")) {
                    input(.type(.hidden), .name("ticket"), .value(ticket))
                    fieldset(.class("fieldset-plain")) {
                        legend(.class("visually-hidden")) { "Assignments" }
                        div(.class("checkbox-list")) {
                            for assignment in assignments {
                                LTIDeepLinkChoice(assignment: assignment, acceptMultiple: acceptMultiple)
                            }
                        }
                    }
                    div(.class("toolbar toolbar--end")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Add to LMS" }
                    }
                }
            }
        }
    }
}

/// One assignment in the picker.
struct LTIDeepLinkChoice: HTML {
    let assignment: LTIDeepLinkOption
    let acceptMultiple: Bool

    var body: some HTML {
        label(.class("checkbox-row")) {
            if acceptMultiple {
                input(.type(.checkbox), .name("assignments[]"), .value(assignment.publicID))
            } else {
                input(.type(.radio), .name("assignments[]"), .value(assignment.publicID), .required)
            }
            assignment.title
        }
    }
}
