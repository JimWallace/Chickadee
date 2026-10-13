// APIServer/Views/Pages/WorkbenchPage.swift
//
// GET /instructor/:assignmentID/workbench: the assignment editor and the
// notebook editor side by side, in one document (#1266). The full-bleed app:
// the page owns the viewport and its panes scroll inside it.
//
// The left pane is `AssignmentEditBody`, the body of the standalone edit page.
// The right pane is `NotebookBody`, the body of the standalone notebook page,
// with its one `#jl-frame` editor iframe. One copy of each body serves both
// surfaces, so the panes cannot drift from the pages they mirror.

import Elementary

struct WorkbenchPage: HTML {
    let page: PageRequestContext
    let assignmentID: String
    let testSetupID: String
    /// The assignment's trimmed title, or "Assignment" when it is blank.
    let assignmentTitle: String
    /// The left pane's content. Built with `embedded: true`.
    let edit: EditAssignmentContext
    /// The right pane's content, or nil when the assignment has no notebook on
    /// disk yet. Optional on purpose: a missing notebook degrades the pane to
    /// a placeholder, and the edit half stays usable (uploading a starter is
    /// one of the things it is for).
    let notebook: NotebookBody?
    /// `{"<file>:<view>": "<url>"}` for every (file, view) that exists. The
    /// view switch and the Files table look up the destination here.
    let notebookPaneURLsJSON: String
    /// Per file: whether the stored notebook still carries `{{name}}`, so its
    /// template and its rendering differ and the view switch means something.
    let assignmentHasTemplateView: Bool
    let solutionHasTemplateView: Bool

    var body: some HTML {
        // `fullBleed` drops `.main`'s reading-column cap. `inPlaceForms` is
        // load-bearing: every write in the edit half answers with a redirect,
        // and a navigation would tear down the kernel in the notebook half.
        BaseLayout(
            title: "\(assignmentTitle) — Workbench", page: page, fullBleed: true, inPlaceForms: true
        ) {
            PageStyle(
                """
                /* The workbench owns the viewport: the panes scroll internally, the page never
                   does.  The reading-column cap is dropped by `fullBleed` on the context, which
                   adds `.main-fullbleed` in BaseLayout. */
                .wb-shell {
                    display: flex;
                    flex-direction: column;
                    /* 100% of what `.page-fullbleed` hands us, not of the viewport: the site
                       nav is above us and taking the whole window would push the document
                       taller than the screen.  The viewport measurement (`100dvh`, chosen over
                       `vh` because mobile browsers shrink the visual viewport when their chrome
                       appears) now lives on the body, once. */
                    height: 100%;
                    min-height: 0;
                }

                .wb-bar {
                    display: flex;
                    align-items: center;
                    gap: .75rem;
                    flex: 0 0 auto;
                    padding: .4rem .75rem;
                    border-bottom: 1px solid var(--border);
                    background: var(--surface-muted);
                }
                .wb-bar-spacer { flex: 1; }
                .wb-save-status {
                    font-size: var(--text-sm);
                    color: var(--gray-700);
                }
                /* Which notebook the pane is showing.  A label, not a control — the choosing
                   happens in the left pane's Files table. */
                .wb-openfile {
                    font-size: var(--text-sm);
                    font-weight: 600;
                }

                /* Three columns: left pane, splitter, right pane.  min-height:0 on the body
                   and min-width:0 on the panes are what let the grid children actually shrink
                   — without them a grid item's automatic minimum size is its content, and the
                   iframes would push the layout wider than the viewport. */
                .wb-body {
                    flex: 1;
                    display: grid;
                    grid-template-columns: var(--wb-left-width) auto 1fr;
                    min-height: 0;
                }
                .wb-pane {
                    min-width: 0;
                    min-height: 0;
                    display: flex;
                    flex-direction: column;
                }
                /* Both panes hold real content now, not iframes, so the internal scrolling an
                   iframe gave for free has to be asked for.  The page itself still never
                   scrolls — `.wb-shell` is pinned to the viewport. */
                .wb-scroll {
                    flex: 1;
                    min-height: 0;
                    overflow-y: auto;
                    overflow-x: hidden;
                }
                /* The notebook half is the exception: its editor fills the pane, so it must not
                   scroll as a block. */
                .wb-notebook-body {
                    display: flex;
                    flex-direction: column;
                    overflow-y: hidden;
                }
                /* The edit half needs its own gutter. It used to inherit one from the pane
                   document's `.main`; inlined, its content would otherwise sit flush against
                   the viewport edge. */
                .wb-pane-edit { padding: 0 .75rem; }

                .wb-splitter {
                    width: .5rem;
                    cursor: col-resize;
                    border: 0;
                    padding: 0;
                    background: var(--border);
                    /* Widen the grab area beyond the visible line without widening the column. */
                    box-shadow: 0 0 0 .25rem transparent;
                }
                .wb-splitter:hover,
                .wb-splitter:focus-visible { background: var(--health-teal); }

                .wb-panehead {
                    display: flex;
                    align-items: center;
                    gap: .4rem;
                    flex: 0 0 auto;
                    padding: .3rem .5rem;
                    border-bottom: 1px solid var(--border);
                }
                .wb-viewswitch {
                    display: flex;
                    align-items: center;
                    gap: .25rem;
                    margin-left: .5rem;
                    padding-left: .5rem;
                    border-left: 1px solid var(--border);
                }
                .wb-view[aria-pressed="true"] {
                    background: var(--health-teal);
                    color: var(--surface);
                }

                /* Below the point where an honest split is possible (720px notebook floor +
                   380px edit floor + the splitter), collapse to one pane at a time.  The
                   notebook page hides its own editor under 640px, so a too-narrow pane would
                   render "open on a larger screen" instead of the editor — the failure this
                   breakpoint exists to prevent. */
                @media (max-width: 1140px) {
                    .wb-body { grid-template-columns: 1fr; }
                    .wb-splitter { display: none; }
                    .wb-shell[data-wb-single="edit"] .wb-pane-notebook { display: none; }
                    .wb-shell[data-wb-single="notebook"] .wb-pane-edit { display: none; }
                }
                """
            )
            div(
                .class("wb-shell"), .id("wb-shell"), .data("assignment-id", value: assignmentID),
                .data("setup-id", value: testSetupID), .data("wb-single", value: "notebook"),
                .data("wb-pane-urls", value: notebookPaneURLsJSON)
            ) {
                // The bar carries one control. `#wb-single-edit` is the
                // exception: below 1140px the panes stack and it is the only
                // way back to the editor, so it appears only at that width.
                div(.class("wb-bar")) {
                    span(.class("wb-bar-spacer")) {}
                    " "
                    span(.class("wb-save-status"), .id("wb-save-status"), .role("status")) {}
                    " "
                    button(.class("btn action-btn"), .type(.button), .id("wb-single-edit"), .hidden) { "Editor" }
                    " "
                    button(
                        .class("btn btn-primary"), .type(.button), .id("wb-save"),
                        .title("Save the open notebook and the assignment's details, then re-validate")
                    ) { "Save" }
                }
                div(.class("wb-body")) {
                    section(.class("wb-pane wb-pane-edit wb-scroll"), .ariaLabel("Assignment editor")) {
                        AssignmentEditBody(edit: edit, csrfToken: page.csrfToken, appVersion: page.appVersion)
                    }
                    button(
                        .class("wb-splitter"), .id("wb-splitter"), .type(.button), .role("separator"),
                        .custom(name: "aria-orientation", value: "vertical"), .ariaLabel("Resize panes"),
                        .custom(name: "aria-valuemin", value: "0"), .custom(name: "aria-valuemax", value: "100"),
                        .custom(name: "aria-valuenow", value: "42")
                    ) {}
                    section(.class("wb-pane wb-pane-notebook"), .ariaLabel("Notebook editor")) {
                        paneHead
                        notebookPane
                    }
                }
            }
            script(.src(page.asset("/workbench.js"))) {}
        }
    }

    /// Which notebook is open, and the view switch. The switch renders hidden;
    /// `workbench.js` shows it only when the open file has placeholders, since
    /// otherwise the two readings are byte-identical.
    private var paneHead: some HTML {
        let isTemplateView = notebook?.isTemplateView == true
        return div(.class("wb-panehead")) {
            span(.class("wb-openfile"), .id("wb-openfile")) { "Assignment" }
            div(
                .class("wb-viewswitch"), .id("wb-viewswitch"), .role("group"), .ariaLabel("Notebook view"),
                .data("assignment-has-template", value: assignmentHasTemplateView ? "1" : "0"),
                .data("solution-has-template", value: solutionHasTemplateView ? "1" : "0"), .hidden
            ) {
                // `aria-pressed` follows the view actually open: the server
                // defaults course staff to the template on a notebook that
                // carries placeholders (`resolveNotebookViewMode`).
                button(
                    .class("btn action-btn wb-view"), .type(.button), .data("wb-view", value: "personalized"),
                    .custom(name: "aria-pressed", value: isTemplateView ? "false" : "true"),
                    .title("The notebook as a student sees it, with values substituted")
                ) { "With values" }
                " "
                button(
                    .class("btn action-btn wb-view"), .type(.button), .data("wb-view", value: "template"),
                    .custom(name: "aria-pressed", value: isTemplateView ? "true" : "false"),
                    .title("The authored template, with placeholders left standing")
                ) { "Template" }
            }
            span(.class("wb-bar-spacer")) {}
            " "
            // Set by workbench.js when a left-pane edit invalidates what the
            // notebook shows. Advisory only: reloading the pane would restart the
            // kernel and lose the author's live state, so the author chooses when.
            span(.class("chip"), .id("wb-stale-chip"), .role("status"), .hidden) {}
        }
    }

    /// The notebook body, or the stand-in when the assignment has no notebook
    /// yet. Still one notebook at a time: switching file or view is an
    /// ordinary navigation to this route, looked up in `data-wb-pane-urls`.
    @HTMLBuilder private var notebookPane: some HTML {
        if let notebook {
            div(
                .class("wb-notebook-body wb-scroll"), .data("wb-file", value: notebook.fileKind),
                .data("wb-view", value: notebook.isTemplateView ? "template" : "personalized")
            ) {
                notebook
            }
        } else {
            div(.class("standin-panel"), .role("note")) {
                h2(.class("standin-panel-title")) { "No notebook yet" }
                p(.class("standin-panel-text")) {
                    "This assignment has no starter notebook. Upload one in the Files table on the left and it will open here."
                }
            }
        }
    }
}
