// APIServer/Views/Pages/AdminEnrollCSVResultPage.swift
//
// The result of a CSV bulk enrollment, shared by the admin route
// (POST /admin/courses/:courseID/enroll-csv) and the instructor route
// (POST /courses/:courseID/enroll-csv).

import Elementary

struct AdminEnrollCSVResultPage: HTML {
    let page: PageRequestContext
    let courseCode: String
    let courseName: String
    let result: EnrollUsernamesResult
    /// Where the back button goes: the admin course page or /instructor.
    let returnURL: String

    var body: some HTML {
        BaseLayout(title: "CSV Enrollment Result", page: page) {
            div(.class("page-titlebar")) {
                h1 { "CSV Enrollment — \(courseCode)" }
                a(.href(returnURL), .class("btn")) { "← \(courseCode)" }
            }
            p(.class("page-subtitle")) { courseName }
            section(.class("page-section")) {
                h2 { "Results" }
                div(.class("card section-gap")) {
                    dl(.class("detail-grid")) {
                        dt { "Enrolled (existing accounts)" }
                        dd { "\(result.enrolledCount)" }
                        dt { "Pre-enrolled" }
                        dd { "\(result.preEnrolledCount)" }
                        dt { "Already enrolled (skipped)" }
                        dd { "\(result.alreadyEnrolledCount)" }
                        dt { "Rejected (invalid format)" }
                        dd { "\(result.rejectedUsernames.count)" }
                    }
                }
                if result.preEnrolledCount > 0 {
                    p(.class("section-note")) {
                        "Each pre-enrolled username joins the roster the first time that student signs in."
                    }
                }
            }
            if !result.rejectedUsernames.isEmpty {
                section(.class("page-section")) {
                    h2 { "Rejected usernames" }
                    p(.class("section-note")) {
                        "These usernames are too long or hold unsupported characters; correct them and submit again."
                    }
                    ul(.class("csv-rejected-list")) {
                        for name in result.rejectedUsernames {
                            li { code { name } }
                        }
                    }
                }
            }
            PageStyle(
                """
                .csv-rejected-list { margin-left: 1.25rem; }
                """
            )
        }
    }
}
