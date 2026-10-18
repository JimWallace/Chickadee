// APIServer/Views/Pages/JoinSessionPage.swift
//
// GET /join: where a student types the code on the lab's screen
// (docs/lab-groups.md, slice 2). A right code goes straight to the
// assignment; a wrong one comes back here with the reason.

import Elementary

struct JoinSessionPage: HTML {
    let page: PageRequestContext
    var error: String?
    var code: String = ""

    var body: some HTML {
        BaseLayout(title: "Join a session", page: page, flash: FlashMessages(error: error)) {
            h1 { "Join a session" }
            p(.class("section-intro")) { "Enter the code on the screen in your lab." }
            form(.method(.post), .action("/join"), .class("form-stack")) {
                CSRFField(token: page.csrfToken)
                label(.class("form-label")) {
                    "Code"
                    input(
                        .class("form-input"), .type(.text), .name("code"), .value(code), .required,
                        .maxlength(12), .autocomplete(.off))
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Join" }
                }
            }
        }
    }
}
