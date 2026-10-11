// APIServer/Views/Pages/AdminUserPage.swift
//
// GET /admin/users/:userID: one user's course enrollments, with remove and
// add actions. The Elementary port of `admin-user.leaf`, the exemplar of the
// titlebar archetype (docs/ui-design.md).

import Elementary

struct AdminUserPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let targetUserID: String
    let displayName: String?
    let username: String
    let role: String
    let enrolledCourses: [AdminCourseRef]
    let availableCourses: [AdminCourseRef]

    private var heading: String {
        guard let displayName, !displayName.isEmpty else { return username }
        return displayName
    }

    var body: some HTML {
        BaseLayout(title: "Courses — \(heading)", page: page, flash: flash) {
            div(.class("page-titlebar")) {
                h1 { "\(heading) — Courses" }
            }
            p(.class("page-subtitle")) { "@\(username) · \(role)" }
            enrolledSection
            addSection
            PageStyle(
                """
                .user-enroll-form { max-width: 500px; }
                .user-enroll-select { flex: 1; }
                """
            )
        }
    }

    private var enrolledSection: some HTML {
        section(.class("page-section")) {
            h2 { "Enrolled courses" }
            if enrolledCourses.isEmpty {
                p(.class("empty")) { "Not enrolled in any courses." }
            } else {
                table(.class("results-table")) {
                    thead {
                        tr {
                            th { "Course" }
                            th { "Name" }
                            th { "Actions" }
                        }
                    }
                    tbody {
                        for course in enrolledCourses {
                            EnrolledCourseRow(
                                course: course, targetUserID: targetUserID, csrfToken: page.csrfToken)
                        }
                    }
                }
            }
        }
    }

    private var addSection: some HTML {
        section(.class("page-section")) {
            h2 { "Add to course" }
            if availableCourses.isEmpty {
                p(.class("empty")) {
                    enrolledCourses.isEmpty ? "No active courses are available." : "Enrolled in all active courses."
                }
            } else {
                form(
                    .method(.post), .action("/admin/users/\(targetUserID)/enroll"),
                    .class("toolbar user-enroll-form")
                ) {
                    CSRFField(token: page.csrfToken)
                    select(.name("courseID"), .class("form-input user-enroll-select")) {
                        for course in availableCourses {
                            option(.value(course.id)) { "\(course.label) — \(course.name)" }
                        }
                    }
                    button(.class("btn btn-primary"), .type(.submit)) { "Add" }
                }
            }
        }
    }
}

/// One enrolled course, with its remove action.
struct EnrolledCourseRow: HTML {
    let course: AdminCourseRef
    let targetUserID: String
    let csrfToken: String

    var body: some HTML {
        tr {
            td {
                strong { course.code }
                if let term = course.termLabel { " \(term)" }
            }
            td { course.name }
            td {
                form(
                    .method(.post), .action("/admin/users/\(targetUserID)/unenroll/\(course.id)"),
                    .class("inline-form")
                ) {
                    CSRFField(token: csrfToken)
                    button(
                        .class("btn action-btn action-btn-icon action-danger"), .type(.submit),
                        .title("Remove from course"), .ariaLabel("Remove from course")
                    ) {
                        Icon("i-trash")
                    }
                }
            }
        }
    }
}
