// APIServer/Views/Pages/InstructorNewTermPage.swift
//
// GET /instructor/new-term: the New term tab. Clone the active course into a
// new offering (docs/course-terms.md slice 5), or, right after a clone, point
// to the new course's assignments.

import Elementary

struct InstructorNewTermPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    let courseName: String
    /// "Fall 2026", or nil when the active course records no term.
    let termLabel: String?
    /// True for a per-course instructor or an admin. A TA sees the tab but
    /// not the form: creating a course is a lifecycle act.
    let canClone: Bool
    /// True on the page shown right after a clone: the active course is now
    /// the new one, so the page points to its assignments, not to a second
    /// clone.
    let justCloned: Bool
    /// The form, with the term after the active course's selected. Its error
    /// stays nil: the page shows a refusal as a flash banner.
    let cloneForm: CourseFieldsContext

    private var termSuffix: String {
        termLabel.map { " \($0)" } ?? ""
    }

    var body: some HTML {
        BaseLayout(title: "New term", page: page, flash: flash) {
            InstructorTabs(active: .newTerm)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to clone it for a new term." }
                }
            } else if justCloned {
                section(.class("page-section")) {
                    h2 { "\(courseCode)\(termSuffix) — \(courseName)" }
                    p(.class("section-intro")) {
                        "This is the new course. Its assignments are closed and have no dates."
                    }
                    div(.class("toolbar")) {
                        a(.class("btn btn-primary"), .href("/instructor")) { "Open its assignments" }
                    }
                }
            } else {
                section(.class("page-section")) {
                    h2 { "Clone \(courseCode)\(termSuffix) for a new term" }
                    p(.class("section-intro")) {
                        "Copies this course's content into a new course that you teach; students, submissions "
                        "and grades stay here."
                    }
                    p(.class("section-note")) {
                        "Copied assignments start closed, with no dates and with the solution reveal off."
                    }
                    if canClone {
                        form(.method(.post), .action("/instructor/new-term"), .class("form-stack")) {
                            CSRFField(token: page.csrfToken)
                            CourseFields(form: cloneForm)
                            div(.class("toolbar")) {
                                button(.class("btn btn-primary"), .type(.submit)) { "Clone course" }
                            }
                        }
                    } else {
                        p(.class("section-note")) { "Only this course's instructors can clone it." }
                    }
                }
            }
        }
    }
}
