// APIServer/Views/NotebookToolbar.swift
//
// The notebook editor's one toolbar (design frame 18a, notebook views NB2).
// The editor's own top area, menu bar and notebook toolbar are hidden, so the
// page drives the editor from here: the title and due date, the save state,
// Run · Run all · + Code · + Text, the kernel chip, the ⋯ menu and Submit.
//
// The edit buttons and the menu's editor items name JupyterLab commands in
// `data-nb-commands` (space-separated, run in order). `notebook-toolbar.js`
// runs them through the jupyter-iframe-commands bridge. The ids below are read
// by `notebook.js`, `notebook-boot.js` and `notebook-toolbar.js`.

import Elementary

struct NotebookToolbar<Status: HTML>: HTML {
    let notebook: NotebookBody
    /// The page's status line, which `NotebookBody` owns.
    let status: Status

    var body: some HTML {
        div(.class("notebook-toolbar")) {
            if !notebook.embedded, let title = notebook.assignmentTitle {
                div(.class("nb-title-block")) {
                    strong { title }
                    if let due = notebook.dueLabel {
                        span(.class("card-meta")) { "Due \(due)" }
                    }
                }
            }
            // notebook-toolbar.js writes the editor's save state here.
            span(.class("text-quiet"), .id("nb-save-state"), .hidden) {}
            status
            div(.class("notebook-actions")) {
                // The " " after each control keeps the spaces between them.
                if !notebook.isReadOnly {
                    editActions
                    " "
                }
                kernelChip
                " "
                RowMenu(for: "the notebook") { menuItems }
                " "
                staffControls
                headerNotice
            }
        }
    }

    /// Run, Run all, + Code and + Text: the commands confirmed against the
    /// vendored JupyterLab 4.6.4.
    private var editActions: some HTML {
        div(.class("toolbar nb-edit-actions"), .role("toolbar"), .ariaLabel("Notebook")) {
            command("▶ Run", "notebook:run-cell-and-select-next", title: "Run the cell and select the next one")
            command("Run all", "notebook:run-all-cells", title: "Run every cell from the top")
            command("+ Code", "notebook:insert-cell-below notebook:change-cell-to-code", title: "Add a code cell below")
            command(
                "+ Text", "notebook:insert-cell-below notebook:change-cell-to-markdown", title: "Add a text cell below")
        }
    }

    private func command(_ label: String, _ commands: String, title: String) -> some HTML {
        button(.type(.button), .class("btn"), .data("nb-commands", value: commands), .title(title)) { label }
    }

    /// The kernel's state: amber while it starts or runs, teal when it is
    /// idle. notebook-boot.js and notebook-toolbar.js write the state.
    private var kernelChip: some HTML {
        span(.id("nb-kernel-chip"), .class("kernel-chip"), .data("state", value: "starting")) {
            "\(notebook.kernelLanguage ?? "Kernel") · "
            span(.class("js-nb-kernel-state")) { "starting" }
        }
    }

    @HTMLBuilder private var menuItems: some HTML {
        if let downloadURL = notebook.downloadURL, !notebook.embedded {
            a(
                .class("row-menu-item"), .role("menuitem"), .href(downloadURL),
                HTMLAttribute(name: "download", value: nil)
            ) {
                "Download"
            }
        }
        if notebook.showSubmit {
            // A button, so the keyboard reaches it; notebook-toolbar.js opens
            // the hidden file input, and notebook.js submits the chosen file,
            // as from the failure panel.
            button(
                .type(.button), .class("row-menu-item"), .role("menuitem"),
                .data("nb-upload", value: "nb-menu-upload-file")
            ) { "Upload .ipynb" }
            input(
                .type(.file), .id("nb-menu-upload-file"), .class("visually-hidden"), .tabindex(-1),
                .accept(".ipynb,application/json"), .ariaLabel("Upload your .ipynb file"))
        }
        if !notebook.isReadOnly {
            // The editor asks before it restarts the kernel.
            button(
                .type(.button), .class("row-menu-item"), .role("menuitem"),
                .data("nb-commands", value: "notebook:restart-kernel")
            ) { "Restart kernel" }
        }
        if !notebook.isReadOnly {
            button(
                .type(.button), .class("row-menu-item"), .role("menuitem"),
                .data("nb-commands", value: "notebook:clear-all-cell-outputs")
            ) { "Clear outputs" }
        }
        a(
            .class("row-menu-item"), .role("menuitem"),
            .href("https://github.com/JimWallace/Chickadee/blob/main/docs/notebook-editor-help.md"),
            .target(.blank), .rel("noopener noreferrer")
        ) {
            "Help "
            Icon("i-external")
            span(.class("visually-hidden")) { "(opens in a new tab)" }
        }
        if notebook.showSubmit, !notebook.embedded, let csrfToken = notebook.csrfToken {
            form(
                .method(.post), .action("/testsetups/\(notebook.testSetupID)/reset-notebook"),
                .class("contents-form"),
                .data("confirm", value: "Reset to the original starter? This discards your current edits.")
            ) {
                CSRFField(token: csrfToken)
                button(.type(.submit), .class("row-menu-item row-menu-item--danger"), .role("menuitem")) {
                    "Reset to starter"
                }
            }
        }
    }

    /// The staff controls the bar kept: the view switch, Save and the
    /// student's solution link.
    @HTMLBuilder private var staffControls: some HTML {
        if let viewToggleURL = notebook.viewToggleURL, !notebook.embedded {
            // Suppressed in a workbench pane: the workbench has its own
            // template/values control, and `viewToggleURL` carries no
            // `embedded=1`.
            a(.class("btn"), .href(viewToggleURL)) {
                notebook.isTemplateView ? "View with values" : "Edit the template"
            }
            " "
        }
        if notebook.canSaveToAssignment {
            // Present but hidden in a workbench pane: the workbench's single
            // Save calls the function notebook.js binds here.
            button(.class("btn btn-primary"), .type(.button), .id("nb-save-assignment")) {
                notebook.fileKind == "solution" ? "Save solution" : "Save to assignment"
            }
            .attributes(.hidden, when: notebook.embedded)
            .attributes(
                .data("file-kind", value: notebook.fileKind),
                .data("view-mode", value: notebook.isTemplateView ? "template" : "personalized"),
                .title("Write what is in this editor back to the assignment for every student")
            )
            " "
        }
        if let solutionViewURL = notebook.solutionViewURL {
            a(.class("btn"), .href(solutionViewURL)) { "View solution" }
            " "
        }
    }

    /// The toolbar's one status notice, or Submit.
    @HTMLBuilder private var headerNotice: some HTML {
        if notebook.isStudentSolutionView {
            span(.class("nb-closed-notice")) {
                "Reference solution"
                if notebook.isReadOnly {
                    " — view only."
                }
            }
        } else if notebook.isTemplateView {
            span(.class("nb-closed-notice")) { "Editing the template — placeholders stand as written." }
        } else if notebook.showSubmit {
            if notebook.aiFeedbackNotice {
                span(.class("nb-closed-notice")) {
                    a(
                        .href(
                            "https://github.com/JimWallace/Chickadee/blob/main/docs/ai-assisted-feedback.md#information-for-students"
                        ),
                        .target(.blank), .rel("noopener noreferrer")
                    ) {
                        "AI-assisted feedback is on "
                        Icon("i-external")
                        span(.class("visually-hidden")) { "(opens in a new tab)" }
                    }
                }
                " "
            }
            button(.class("btn btn-primary"), .type(.button), .id("nb-submit")) { "Submit" }
        } else if notebook.isReadOnly {
            span(.class("nb-closed-notice")) { "This assignment is closed — view only." }
        } else if notebook.isClosed {
            span(.class("nb-closed-notice")) { "This assignment is closed to students — editable as course staff." }
        }
    }
}
