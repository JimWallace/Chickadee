// APIServer/Views/Pages/EnrollPage.swift
//
// GET /enroll: the courses open for self-enrollment, as a checkbox list.

import Elementary

/// One course the viewer may join, and whether they already have.
struct EnrollCourseRow: Sendable {
    let id: String
    let code: String
    let name: String
    /// "Fall 2026", or nil when the course records no term.
    let termLabel: String?
    let isEnrolled: Bool
}

struct EnrollPage: HTML {
    let page: PageRequestContext
    /// The `?error=` code; only `none_selected` shows a message.
    let error: String?
    let courses: [EnrollCourseRow]

    var body: some HTML {
        BaseLayout(title: "Choose Your Courses", page: page) {
            h1 { "Choose your courses" }
            if error == "none_selected" {
                p(.class("form-error"), .role("alert")) { "Please select at least one course to continue." }
            }
            if courses.isEmpty {
                p(.class("empty")) {
                    "No courses are available to enroll in right now. Please check back later or contact your instructor."
                }
            } else {
                form(.method(.post), .action("/enroll")) {
                    CSRFField(token: page.csrfToken)
                    p(.class("enroll-intro")) {
                        "Select the courses you are enrolled in. You can change your enrollment later on your "
                        a(.href("/account")) { "account page" }
                        "."
                    }
                    fieldset(.class("fieldset-plain")) {
                        legend(.class("form-label")) { "Available courses" }
                        div(.class("checkbox-list")) {
                            for course in courses {
                                EnrollCourseCheckbox(course: course)
                            }
                        }
                    }
                    button(.class("btn btn-primary"), .type(.submit)) { "Save and continue" }
                }
            }
        }
    }
}

struct EnrollCourseCheckbox: HTML {
    let course: EnrollCourseRow

    var body: some HTML {
        label(.class("checkbox-row")) {
            input(.type(.checkbox), .name("courseIDs[]"), .value(course.id))
                .attributes(.checked, when: course.isEnrolled)
            span {
                strong { course.code }
                // Leaf's `#if` held for any non-nil string, the empty one too.
                if let term = course.termLabel {
                    " \(term)"
                }
                " — \(course.name)"
            }
        }
    }
}
