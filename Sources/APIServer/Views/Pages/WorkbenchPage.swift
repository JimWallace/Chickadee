// APIServer/Views/Pages/WorkbenchPage.swift
//
// GET /instructor/:assignmentID/workbench: the assignment workbench (#1266,
// notebook views NB6, design frame 18c). One document: a full-width notebook
// with the test suite in a rail on its left, and an app bar above both.
//
// - The app bar: the title (✎ opens the Details sheet), the due date and the
//   language, the view switch (Solution · Starter), the validation pill, the
//   save state and Save & validate.
// - The rail (`WorkbenchRail`): the suite by section, each item linked to its
//   cell, then the assignment's settings. Under 1300px it is the ☰ Suite
//   button, which opens it over the notebook.
// - The sheet: `AssignmentEditBody`, unchanged, in a panel that slides over
//   the notebook and shows one of its blocks at a time. It keeps the class
//   `wb-pane-edit`, because surface-swap.js refreshes it in place after a save.
//
// The notebook is `NotebookBody`, the body of the standalone notebook page,
// with its one `#jl-frame` editor iframe.

import Elementary

struct WorkbenchPage: HTML {
    let page: PageRequestContext
    let assignmentID: String
    let testSetupID: String
    /// The assignment's trimmed title, or "Assignment" when it is blank.
    let assignmentTitle: String
    /// The sheet's content. Built with `embedded: true`.
    let edit: EditAssignmentContext
    /// The notebook, or nil when the assignment has no notebook on disk yet.
    /// Optional on purpose: a missing notebook degrades to a placeholder, and
    /// the sheets stay usable (uploading a starter is one of their jobs).
    let notebook: NotebookBody?
    /// `{"<file>:<view>": "<url>"}` for every (file, view) that exists. The
    /// view switch and the Files table look up the destination here.
    let notebookPaneURLsJSON: String
    let facts: Facts

    /// What the app bar and the rail say about the assignment.
    struct Facts {
        var dueLabel: String?
        /// The declared language's name, or nil for none.
        var languageName: String?
        /// The assignment's `validationStatus`, or nil before any run.
        var validationStatus: String?
        var hasSolution: Bool
        var fileCount: Int
        var inputCount: Int
        var achievementCount: Int
        /// The students Preview as student lists (NB6b).
        var previewStudents: [WorkbenchPreviewStudent] = []
        /// The student the notebook shows, or nil for the author's notebooks.
        var previewed: WorkbenchPreviewStudent?
    }

    var body: some HTML {
        // `fullBleed` drops `.main`'s reading-column cap. `inPlaceForms` is
        // load-bearing: every write in a sheet answers with a redirect, and a
        // navigation would tear down the kernel in the notebook.
        BaseLayout(
            title: "\(assignmentTitle) — Workbench", page: page, fullBleed: true, inPlaceForms: true
        ) {
            div(
                .class("wb-shell"), .id("wb-shell"), .data("assignment-id", value: assignmentID),
                .data("setup-id", value: testSetupID), .data("wb-pane-urls", value: notebookPaneURLsJSON),
                .data("suite-url", value: "/instructor/\(assignmentID)/suite-outline.json")
            ) {
                WorkbenchAppBar(
                    assignmentID: assignmentID, title: assignmentTitle, facts: facts,
                    openFile: notebook?.fileKind ?? "assignment", csrfToken: page.csrfToken)
                div(.class("wb-body")) {
                    WorkbenchRail(
                        facts: facts, activityIsSet: edit.activity.isSet, csrfToken: page.csrfToken,
                        assignmentID: assignmentID)
                    section(.class("wb-pane wb-pane-notebook"), .ariaLabel("Notebook editor")) {
                        notebookPane
                    }
                    // One sheet at a time; workbench.js sets `data-wb-sheet` to the
                    // block it shows and moves focus in and back.
                    aside(
                        .class("wb-sheet wb-pane-edit"), .id("wb-sheet"), .role("region"),
                        .ariaLabel("Assignment settings"), .hidden
                    ) {
                        div(.class("sheet-head")) {
                            button(
                                .class("btn action-btn"), .type(.button), .id("wb-sheet-close"),
                                .ariaLabel("Close the settings panel")
                            ) { "Close" }
                        }
                        AssignmentEditBody(edit: edit, csrfToken: page.csrfToken, appVersion: page.appVersion)
                    }
                }
            }
            script(.src(page.asset("/workbench-rail.js"))) {}
            script(.src(page.asset("/workbench.js"))) {}
        }
    }

    /// The notebook body, or the stand-in when the assignment has no notebook
    /// yet. One notebook at a time: switching file or view swaps this in place,
    /// looked up in `data-wb-pane-urls`.
    /// The pane's view key: `template`, `personalized`, or `student:<token>`
    /// for a preview. workbench.js reads it to know what is open.
    private func paneView(_ notebook: NotebookBody) -> String {
        if let previewed = facts.previewed { return "student:\(previewed.token)" }
        return notebook.isTemplateView ? "template" : "personalized"
    }

    @HTMLBuilder private var notebookPane: some HTML {
        if let notebook {
            div(
                .class("wb-notebook-body wb-scroll"), .data("wb-file", value: notebook.fileKind),
                .data("wb-view", value: paneView(notebook))
            ) {
                notebook
            }
        } else {
            div(.class("standin-panel"), .role("note")) {
                h2(.class("standin-panel-title")) { "No notebook yet" }
                p(.class("standin-panel-text")) {
                    "This assignment has no starter notebook. Upload one under Files, and it opens here."
                }
            }
        }
    }
}
