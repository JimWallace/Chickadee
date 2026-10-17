// APIServer/Views/WorkbenchRail.swift
//
// The workbench's left rail (notebook views NB6, design frame 18c): the test
// suite by section, then the assignment's settings.
//
// workbench-rail.js draws the suite from `/instructor/:id/suite-outline.json`
// into `#wb-rail-suite`, and draws it again after each save. Each item
// reveals the cell it is linked to. The settings links open a sheet over the
// notebook, which holds the existing edit block unchanged.

import Elementary

struct WorkbenchRail: HTML {
    let facts: WorkbenchPage.Facts
    let activityIsSet: Bool
    let csrfToken: String
    let assignmentID: String

    var body: some HTML {
        nav(.class("wb-rail"), .id("wb-rail"), .ariaLabel("Test suite")) {
            div(.class("rail-head")) {
                h2(.class("outline-caption")) { "Test suite" }
                AddSuiteSectionPopup(assignmentID: assignmentID, csrfToken: csrfToken)
            }
            p(.class("card-meta"), .id("wb-rail-totals")) {}
            // Filled by workbench-rail.js.
            div(.id("wb-rail-suite")) {}
            ul(.class("rail-links")) {
                li {
                    button(.class("outline-row"), .type(.button), .data("wb-open-sheet", value: "suite")) {
                        span(.class("outline-name")) { "Open suite table" }
                    }
                }
            }
            h2(.class("outline-caption")) { "Assignment" }
            ul(.class("rail-links")) {
                sheetLink("Details", sheet: "details", count: nil)
                sheetLink("Files", sheet: "files", count: facts.fileCount)
                sheetLink("Inputs", sheet: "inputs", count: facts.inputCount)
                sheetLink("Student options", sheet: "options", count: nil)
                if activityIsSet {
                    sheetLink("Activity", sheet: "activity", count: nil)
                }
                sheetLink("Achievements", sheet: "achievements", count: facts.achievementCount)
            }
        }
    }

    private func sheetLink(_ label: String, sheet: String, count: Int?) -> some HTML {
        li {
            button(.class("outline-row"), .type(.button), .data("wb-open-sheet", value: sheet)) {
                span(.class("outline-name")) { label }
                if let count {
                    span(.class("card-meta")) { String(count) }
                }
            }
        }
    }
}
