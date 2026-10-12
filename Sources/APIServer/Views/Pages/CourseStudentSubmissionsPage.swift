// APIServer/Views/Pages/CourseStudentSubmissionsPage.swift
//
// GET /:courseCode/students/:urlToken/submissions: one student's assignments
// in a course, grouped by course section, with the staff row actions.

import Elementary

struct CourseStudentSubmissionsPage: HTML {
    let page: PageRequestContext
    let studentName: String
    let studentUsername: String
    /// "CS135 — Design".
    let courseName: String
    let backURL: String
    /// Every course section, each with its rows; a section with no rows is
    /// skipped.
    let sections: [StudentAssignmentSectionContext]
    let ungroupedRows: [StudentAssignmentRow]
    /// True when the course has any section, even one with no rows. It is
    /// what heads the ungrouped rows with "Ungrouped".
    let hasSections: Bool

    var body: some HTML {
        BaseLayout(title: "\(studentName) — Submissions", page: page) {
            div(.class("page-titlebar page-titlebar--baseline")) {
                div {
                    h1 { studentName }
                    p(.class("titlebar-subtitle")) {
                        strong { studentUsername }
                        " in \(courseName)"
                    }
                }
                a(.class("btn action-btn"), .href(backURL)) { "Back to Instructor Dashboard" }
            }
            if !hasSections && ungroupedRows.isEmpty {
                p(.class("empty")) { "No published assignments in this course yet." }
            } else {
                if hasSections {
                    for section in sections where !section.rows.isEmpty {
                        h2(.class("assignment-section-heading")) { section.name }
                        StudentAssignmentTable(rows: section.rows, csrfToken: page.csrfToken)
                    }
                }
                if !ungroupedRows.isEmpty {
                    if hasSections {
                        h2(.class("assignment-section-heading")) { "Ungrouped" }
                    }
                    StudentAssignmentTable(rows: ungroupedRows, csrfToken: page.csrfToken)
                }
            }
        }
    }
}
