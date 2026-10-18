// APIServer/Views/Pages/AdminImportResultPage.swift
//
// POST /admin/courses/import: what a course bundle import created.

import Elementary
import Foundation

struct AdminImportResultPage: HTML {
    let page: PageRequestContext
    let tally: ImportTally

    private var coursePath: String { "/admin/courses/\(tally.courseID.uuidString)" }

    var body: some HTML {
        BaseLayout(title: "Import result — Admin", page: page) {
            div(.class("page-titlebar")) {
                div(.class("toolbar")) {
                    h1 { "Bundle imported" }
                    span(.class("tier tier-open")) { "success" }
                }
            }
            section(.class("page-section")) {
                h2 {
                    tally.courseCode
                    if let termLabel = tally.termLabel { " \(termLabel)" }
                    " — \(tally.courseName)"
                }
                if tally.termLabel == nil {
                    FlashBanner(.warning) {
                        "The bundle has no year and term. Set them on the "
                        a(.href(coursePath)) { "course page" }
                        "."
                    }
                }
                div(.class("card section-gap")) {
                    dl(.class("detail-grid")) {
                        dt { "Test setups" }
                        dd { "\(tally.testSetupsImported)" }
                        dt { "Assignments" }
                        dd { "\(tally.assignmentsImported)" }
                        dt { "Datasets" }
                        dd { "\(tally.datasetsImported)" }
                        dt { "Users matched" }
                        dd { "\(tally.usersMatched)" }
                        dt { "Users created" }
                        dd { "\(tally.usersCreated)" }
                        dt { "Submissions" }
                        dd { "\(tally.submissionsImported)" }
                        dt { "Results" }
                        dd { "\(tally.resultsImported)" }
                    }
                }
                p(.class("section-note")) {
                    "Assignments keep their open or closed state; validation is reset, so re-run it from each assignment page."
                }
                if tally.usersCreated > 0 {
                    p(.class("section-note")) {
                        "New accounts have no password; they sign in through SSO or a password reset."
                    }
                }
                div(.class("toolbar")) {
                    a(.href(coursePath), .class("btn btn-primary")) { "View course" }
                    a(.href("/admin"), .class("btn")) { "Admin dashboard" }
                }
            }
        }
    }
}
