// APIServer/Views/WorkbenchAppBar.swift
//
// The workbench's app bar (notebook views NB6, design frame 18c): the title
// and its ✎, the due date and the language, the view switch, the validation
// pill, the save state and Save & validate.

import Elementary

struct WorkbenchAppBar: HTML {
    let assignmentID: String
    let title: String
    let facts: WorkbenchPage.Facts
    /// `assignment` or `solution`: which notebook is open.
    let openFile: String
    let csrfToken: String

    var body: some HTML {
        header(.class("wb-appbar")) {
            // Under 1300px the rail is hidden; this opens it over the notebook.
            button(
                .class("btn action-btn wb-rail-toggle"), .type(.button), .id("wb-rail-toggle"),
                .custom(name: "aria-controls", value: "wb-rail"), .custom(name: "aria-expanded", value: "false")
            ) { "☰ Suite" }
            div(.class("nb-title-block")) {
                span(.class("toolbar")) {
                    strong(.class("wb-title")) { title }
                    button(
                        .class("btn-link icon-btn-text"), .type(.button), .data("wb-open-sheet", value: "details"),
                        .title("Edit details"), .ariaLabel("Edit the assignment details")
                    ) { "✎" }
                }
                if let meta = metaLine {
                    span(.class("card-meta")) { meta }
                }
            }
            viewSwitch
            span(.class("wb-bar-spacer")) {}
            // Set by workbench.js when a sheet edit makes the notebook stale.
            // Advisory only: reloading the notebook would restart the kernel.
            span(.class("field-note"), .id("wb-stale-chip"), .role("status"), .hidden) {}
            span(.class(pillClass), .id("wb-validation"), .role("status")) { pillText }
            span(.class("wb-save-status"), .id("wb-save-status"), .role("status")) {}
            button(.class("btn btn-primary"), .type(.button), .id("wb-save")) { "Save & validate" }
        }
    }

    /// "Due Thu Oct 23, 23:59 · Python", or nil when there is neither.
    private var metaLine: String? {
        let parts = [facts.dueLabel.map { "Due \($0)" }, facts.languageName].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Solution · Starter. Each opens its notebook as written, placeholders
    /// and all; workbench.js swaps the notebook in place. With no solution
    /// yet, "Create solution" stands where Solution would be.
    private var viewSwitch: some HTML {
        div(.class("toolbar wb-viewswitch"), .id("wb-viewswitch"), .role("group"), .ariaLabel("Notebook")) {
            if facts.hasSolution {
                fileButton("Solution", file: "solution")
            } else {
                form(
                    .method(.post), .action("/instructor/\(assignmentID)/create-solution"), .class("inline-form"),
                    .dataFlag("ck-inplace")
                ) {
                    CSRFField(token: csrfToken)
                    button(.class("btn action-btn"), .type(.submit)) { "Create solution" }
                }
            }
            " "
            fileButton("Starter", file: "assignment")
        }
    }

    private func fileButton(_ label: String, file: String) -> some HTML {
        button(
            .class("btn action-btn wb-view"), .type(.button), .data("wb-target-file", value: file),
            .custom(name: "aria-pressed", value: openFile == file ? "true" : "false")
        ) { label }
    }

    // MARK: - The validation pill

    /// NB8 replaces this with the issues pill.
    private var pillText: String {
        switch facts.validationStatus {
        case "passed": "✓ Validated"
        case "failed": "✗ Validation failed"
        case "pending": "Validating…"
        case "no-runner": "No runner"
        default: "Not validated"
        }
    }

    private var pillClass: String {
        switch facts.validationStatus {
        case "passed": "chip chip-ok"
        case "failed", "no-runner": "chip chip-err"
        default: "chip"
        }
    }
}
