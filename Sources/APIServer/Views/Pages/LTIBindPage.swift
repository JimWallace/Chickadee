// APIServer/Views/Pages/LTIBindPage.swift
//
// GET /lti/bind: an instructor links the LMS course they launched from to one
// of their Chickadee courses (docs/lti-1-3.md "Courses").

import Elementary

struct LTIBindPage: HTML {
    let page: PageRequestContext
    /// The LMS course's title, from the launch.
    let contextTitle: String
    let courses: [LTIBindCourseOption]

    var body: some HTML {
        BaseLayout(title: "Link LMS course", page: page) {
            h1 { "Link LMS course" }
            p(.class("section-intro")) {
                "Choose the Chickadee course for "
                strong { contextTitle }
                ". Launches from this LMS course then go to it, and students are enrolled on their first launch."
            }
            if courses.isEmpty {
                p(.class("empty")) { "No unlinked Chickadee course is available to you." }
                p(.class("section-note")) {
                    "Ask an administrator to create the course, or to add you as its instructor. "
                    a(.href("/")) { "Go to your dashboard" }
                }
            } else {
                form(.method(.post), .action("/lti/bind"), .class("form-stack")) {
                    CSRFField(token: page.csrfToken)
                    LTICourseSelect(id: "lti-bind-course", courses: courses)
                    div(.class("toolbar toolbar--end")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Link course" }
                    }
                }
            }
        }
    }
}

/// The course choice both LMS binding pages show.
struct LTICourseSelect: HTML {
    let id: String
    let courses: [LTIBindCourseOption]

    var body: some HTML {
        div(.class("field-stack")) {
            label(.for(id)) { "Chickadee course" }
            select(.id(id), .class("form-input"), .name("courseID"), .required) {
                option(.value(""), .selected, .disabled) { "Choose a course" }
                for course in courses {
                    option(.value(course.id)) { Self.optionText(course) }
                }
            }
        }
    }

    static func optionText(_ course: LTIBindCourseOption) -> String {
        guard let term = course.termLabel else { return "\(course.code) — \(course.name)" }
        return "\(course.code) \(term) — \(course.name)"
    }
}
