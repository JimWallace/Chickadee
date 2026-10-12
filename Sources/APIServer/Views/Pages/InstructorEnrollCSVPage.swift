// APIServer/Views/Pages/InstructorEnrollCSVPage.swift
//
// GET /instructor/enroll-csv: the form that enrols students in the active
// course from a CSV file or typed user IDs. The POST handler renders it again
// with an error when neither was supplied.

import Elementary

struct InstructorEnrollCSVPage: HTML {
    let page: PageRequestContext
    let courseID: String
    let courseCode: String
    let courseName: String
    /// The form error. Shown when present, even when empty, as the template
    /// did.
    let error: String?

    var body: some HTML {
        BaseLayout(title: "Enrol from CSV — \(courseCode)", page: page) {
            div(.class("page-titlebar enroll-csv-titlebar")) {
                h1 { "Enrol from CSV" }
                span(.class("enroll-csv-course-name")) { "\(courseCode) — \(courseName)" }
            }
            if let error {
                div(.class("form-error section-gap"), .role("alert")) { error }
            }
            section(.class("page-section")) {
                h2 { "Add students" }
                p(.class("section-intro")) {
                    "Upload a CSV file, type user IDs directly, or both — supplied IDs are merged. Unknown IDs are "
                        + "recorded as pending enrolments and resolved when the student first signs in."
                }
                form(
                    .method(.post), .action("/courses/\(courseID)/enroll-csv"), .enctype(.multipartFormData),
                    .class("form-stack")
                ) {
                    CSRFField(token: page.csrfToken)
                    " "
                    label(.class("form-label")) {
                        "Upload a CSV"
                        input(
                            .class("form-input enroll-csv-file-input"), .type(.file), .name("file"),
                            .accept(".csv,.txt"))
                        " "
                        span(.class("enroll-csv-hint")) {
                            "One username per line. The first column is used, and a header row like "
                            code { "username" }
                            " is ignored automatically."
                        }
                        " "
                    }
                    " "
                    label(.class("form-label")) {
                        "Or type user IDs"
                        textarea(
                            .class("form-input textarea-mono"), .name("usernames"), .rows(5),
                            .placeholder("alice\nbob\ncarol")
                        ) {}
                        " "
                        span(.class("enroll-csv-hint")) { "Separate IDs with new lines, commas, or spaces." }
                        " "
                    }
                    div(.class("enroll-csv-form-buttons")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Enrol" }
                        " "
                        a(.href("/instructor"), .class("btn")) { "Cancel" }
                    }
                }
            }
            PageStyle(
                """
                .enroll-csv-titlebar { margin-bottom: 1.5rem; }
                .enroll-csv-course-name { color: var(--text-secondary); }
                .enroll-csv-file-input { display: block; margin-top: .25rem; }
                .enroll-csv-hint { display: block; margin-top: .25rem; color: var(--text-secondary); font-size: var(--text-sm); }
                .enroll-csv-form-buttons { display: flex; gap: .75rem; }
                """
            )
        }
    }
}
