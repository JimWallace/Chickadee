// APIServer/Views/Pages/InstructorLTIGradesPage.swift
//
// GET /instructor/lti-grades: where an instructor sends the active course's
// grades through the LTI grade service instead of the Valence sync, and where
// course staff see what the AGS sweep sent and what failed
// (docs/lti-1-3.md "Grades through AGS"). It sits under the LEARN tab.

import Elementary

struct InstructorLTIGradesPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    /// The LMS the course is linked to; nil = not linked.
    let platformName: String?
    let isLinked: Bool
    /// True once a launch sent the course's line-items URL.
    let hasGradeService: Bool
    let usesAGS: Bool
    /// Instructor, course not archived, and the grade service is known.
    let canChooseTransport: Bool
    /// Course staff on a course that uses AGS and is not archived.
    let canPushAll: Bool
    /// An instructor on a course that uses AGS, is not archived, and has an
    /// NRPS membership URL.
    let canLinkStudents: Bool
    let sentCount: Int
    let waitingCount: Int
    let failedCount: Int
    /// The first failures the route lists; `failedCount` counts them all.
    let failures: [LTIGradeFailureRow]
    let failuresTruncated: Bool

    var body: some HTML {
        BaseLayout(title: "LMS grades", page: page, flash: flash) {
            InstructorTabs(active: .brightspace)
            if canPushAll {
                div(.class("toolbar toolbar--end section-gap")) {
                    form(.method(.post), .action("/instructor/lti-grades/push-all"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        button(.class("btn btn-primary"), .type(.submit)) { "Sync now" }
                    }
                }
            }
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its LMS grades." }
                }
            } else if !isLinked {
                section(.class("page-section")) {
                    h2 { "LMS grades — \(courseCode)" }
                    p(.class("empty")) { "This course is not linked to an LMS course." }
                    p(.class("section-note")) { "An instructor links it by opening Chickadee from the LMS course." }
                }
            } else {
                routeSection
                if usesAGS {
                    activitySection
                }
            }
        }
    }

    private var routeSection: some HTML {
        section(.class("page-section")) {
            h2 { "LMS grades — \(courseCode)" }
            p(.class("section-intro")) {
                "This course is linked to \(platformName ?? ""). Its grades go to the LMS by one route at a time."
            }
            if !hasGradeService {
                p(.class("section-note")) {
                    "Open Chickadee from the LMS course once so that the LMS sends its grade service URL."
                }
            }
            if canChooseTransport {
                transportForm
            } else if usesAGS {
                p(.class("section-note")) { "Grades go through the LTI grade service." }
            } else {
                p(.class("section-note")) { "Grades go through the LEARN grade sync." }
            }
        }
    }

    private var transportForm: some HTML {
        form(.method(.post), .action("/instructor/lti-grades/transport"), .class("form-stack")) {
            CSRFField(token: page.csrfToken)
            fieldset(.class("fieldset-plain")) {
                legend { "Grade route" }
                // Each checkbox row is a flex row, so no space joins the
                // radio and its text.
                div(.class("checkbox-list")) {
                    label(.class("checkbox-row")) {
                        input(.type(.radio), .name("transport"), .value("valence"))
                            .attributes(.checked, when: !usesAGS)
                        "LEARN grade sync"
                    }
                    label(.class("checkbox-row")) {
                        input(.type(.radio), .name("transport"), .value("ags"))
                            .attributes(.checked, when: usesAGS)
                        "LTI grade service"
                    }
                }
            }
            div(.class("toolbar")) {
                button(.class("btn btn-primary"), .type(.submit)) { "Save" }
            }
        }
    }

    private var activitySection: some HTML {
        section(.class("page-section")) {
            h2 { "Grade service activity" }
            div(.class("chip-row")) {
                span(.class("chip chip-ok")) { "\(sentCount) sent" }
                span(.class("chip")) { "\(waitingCount) waiting" }
                if failedCount > 0 {
                    span(.class("chip chip-err")) { "\(failedCount) failed" }
                } else {
                    span(.class("chip chip-ok")) { "0 failed" }
                }
            }
            if !failures.isEmpty {
                div(.class("table-scroll")) {
                    table(.class("results-table")) {
                        thead {
                            tr {
                                th { "Student" }
                                th { "Assignment" }
                                th { "Reason" }
                            }
                        }
                        tbody {
                            for failure in failures {
                                tr {
                                    td { failure.student }
                                    td { failure.assignment }
                                    td { failure.reason }
                                }
                            }
                        }
                    }
                }
                if failuresTruncated {
                    p(.class("section-note")) { "Showing the first \(failures.count)." }
                }
            }
            if canLinkStudents {
                form(.method(.post), .action("/instructor/lti-grades/link-students"), .class("form-stack")) {
                    CSRFField(token: page.csrfToken)
                    div(.class("toolbar")) {
                        button(.class("btn action-btn"), .type(.submit)) { "Link students" }
                    }
                    p(.class("field-note")) {
                        "Links students who have not opened Chickadee from the LMS, by student number."
                    }
                }
            }
        }
    }
}
