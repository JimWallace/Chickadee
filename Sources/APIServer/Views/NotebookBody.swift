// APIServer/Views/NotebookBody.swift
//
// The notebook editor's body: the toolbar, the dismissible notices, the
// failure panel, the JupyterLite iframe and the page scripts. `NotebookPage`
// renders it as the whole page, and `WorkbenchPage` renders it in its
// right-hand pane. It takes plain values and no request.
//
// `_notebook-body.leaf` is no longer served. It stays only because the
// exemplar `workbench.leaf` extends it.
//
// Every id, data attribute, iframe attribute and script tag here is read by
// `Public/notebook*.js`, `Public/browser-runner.js` and the isolation
// middleware. Change none of them without changing their readers.

import Elementary

struct NotebookBody: HTML {
    let testSetupID: String
    let notebookURL: String
    let jupyterLiteEditorURL: String
    let downloadURL: String?
    /// "browser" | "worker".
    let gradingMode: String
    let browserUnsupported: Bool
    let showSubmit: Bool
    let isClosed: Bool
    let isReadOnly: Bool
    let canSaveToAssignment: Bool
    /// "assignment" | "solution".
    let fileKind: String
    let isTemplateView: Bool
    let viewToggleURL: String?
    let solutionViewURL: String?
    let isStudentSolutionView: Bool
    let workingCopyMtime: Int
    /// Rendered into a workbench pane, not as the whole page.
    let embedded: Bool
    let aiFeedbackNotice: Bool
    /// The cache-busting version on the script URLs.
    let appVersion: String

    var body: some HTML {
        // The first part, the `.main` override, only when this body is the page.
        PageStyle(
            embedded
                ? nil
                : """
                /* Override the 900px max-width for this page only.  The default .main also
                   carries a 2rem top+bottom margin (styles.css) — wasted vertical space on the
                   editor page, where every pixel counts on laptops/iPads — so trim it to a
                   hairline top margin and no bottom margin.

                   Emitted only when this body *is* the page.  Embedded (#1266: inlined into
                   the workbench, in the same document as the edit half) `.main` belongs to the
                   host, which sizes itself to the viewport — restyling it from here would
                   reach outside this half and fight `.main-fullbleed`. */
                .main { max-width: 100%; padding: 0 1rem; margin: .5rem auto 0; }
                """,
            """

            /* Closed-assignment "view only" notice. */
            .nb-closed-notice { color: var(--gray-600); font-size: var(--text-base); }

            /* The JupyterLite editor needs room and a pointer; it is unusable on a phone.
               Below 640px we hide the editor surface and show a notice instead.  Tablets
               (641px+) keep the full editor. */
            .nb-smallscreen-notice { display: none; }
            @media (max-width: 640px) {
                .notebook-header,
                #jl-frame,
                #js-nb-fallback,
                #nb-device-warning, #nb-slow-notice,
                #nb-browser-support-warning,
                #nb-results,
                #browser-runner-status { display: none; }
                /* The panel itself is the global .standin-panel; only its appearance at
                   this breakpoint is page-specific. */
                .nb-smallscreen-notice { display: block; }
            }
            """
        )
        div(.class("notebook-header")) {
            div(.class("notebook-toolbar")) {
                span(
                    .class("nb-status"), .id("nb-status"), .role("status"),
                    .custom(name: "aria-live", value: "polite"), .custom(name: "aria-atomic", value: "true"),
                    .tabindex(-1)
                ) {}
                div(.class("notebook-actions")) {
                    // Leaf put each control on its own line; the " " after
                    // each one keeps the spaces between them.
                    headerNotice
                    " "
                    if let viewToggleURL, !embedded {
                        // Suppressed in a workbench pane: the workbench has its
                        // own template/values control, and `viewToggleURL`
                        // carries no `embedded=1`.
                        a(.class("btn"), .href(viewToggleURL)) {
                            isTemplateView ? "View with values" : "Edit the template"
                        }
                        " "
                    }
                    if canSaveToAssignment {
                        // Present but hidden in a workbench pane: the
                        // workbench's single Save calls the function
                        // notebook.js binds here.
                        button(
                            .class("btn btn-primary"), .type(.button), .id("nb-save-assignment")
                        ) {
                            fileKind == "solution" ? "Save solution" : "Save to assignment"
                        }
                        .attributes(.hidden, when: embedded)
                        .attributes(
                            .data("file-kind", value: fileKind),
                            .data("view-mode", value: isTemplateView ? "template" : "personalized"),
                            .title("Write what is in this editor back to the assignment for every student")
                        )
                        " "
                    }
                    if let solutionViewURL {
                        a(.class("btn"), .href(solutionViewURL)) { "View solution" }
                        " "
                    }
                    if let downloadURL, !embedded {
                        // Suppressed in a workbench pane: the left pane's Files
                        // table already links the file.
                        a(.class("btn"), .href(downloadURL), HTMLAttribute(name: "download", value: nil)) { "Download" }
                        " "
                    }
                }
            }
        }
        // The three dismissible notices below are revealed by
        // notebook-preflight.js. They do not block: the editor still loads
        // beneath them.
        FlashBanner(.warning) {
            div(.class("toolbar")) {
                span {
                    strong { "Browser not fully supported." }
                    " You can keep working; your submission is still graded on our servers."
                }
                " "
                dismissButton(id: "nb-browser-support-dismiss", label: "Dismiss browser notice")
            }
        }
        .attributes(.id("nb-browser-support-warning"), .hidden)
        FlashBanner(.warning) {
            div(.class("toolbar")) {
                span {
                    strong { "Low memory." }
                    " If the notebook slows or the kernel stops, use a laptop or desktop."
                }
                " "
                dismissButton(id: "nb-device-warning-dismiss", label: "Dismiss memory notice")
            }
        }
        .attributes(.id("nb-device-warning"), .hidden)
        // The slow-boot notice. notebook-preflight.js writes its title and text
        // from FALLBACK_COPY.slow (notebook-preflight-core.js) when it reveals
        // it. The file input is a second upload path, because the editor may
        // never start.
        FlashBanner(.warning) {
            div(.class("toolbar")) {
                span {
                    strong(.class("js-nb-slow-title")) {}
                    " "
                    span(.class("js-nb-slow-text")) {}
                }
                " "
                uploadInput(id: "nb-slow-upload-file")
                " "
                helpLink(
                    "https://github.com/JimWallace/Chickadee/blob/main/docs/notebook-editor-help.md#the-editor-is-slow-to-load",
                    "More help ")
                " "
                dismissButton(id: "nb-slow-notice-dismiss", label: "Dismiss loading notice")
            }
        }
        .attributes(.id("nb-slow-notice"), .hidden)
        div(.class("nb-smallscreen-notice standin-panel"), .role("note")) {
            h2(.class("standin-panel-title")) { "Open on a larger screen" }
            p(.class("standin-panel-text")) {
                "The notebook editor needs a tablet or computer. Please reopen this "
                    + "assignment on a larger screen to edit and submit your notebook."
            }
        }
        fallbackPanel
        // The editor is booted by notebook.js after the capability preflight
        // resolves (mountEditor sets the iframe src from data-editor-url), not
        // eagerly here: an eager boot raced the preflight's service-worker
        // registration and IndexedDB probes and intermittently left the kernel
        // dead. On phones notebook.js skips the mount, so the iframe stays
        // about:blank.
        iframe(
            .id("jl-frame"),
            .class(embedded ? "jl-frame jl-frame-embedded" : "jl-frame"),
            .title("Notebook editor"),
            .data("setup-id", value: testSetupID),
            .data("grading-mode", value: gradingMode),
            .data("browser-unsupported", value: String(browserUnsupported)),
            .data("notebook-url", value: notebookURL),
            .data("editor-url", value: jupyterLiteEditorURL),
            .data("working-copy-mtime", value: String(workingCopyMtime)),
            .data("read-only", value: String(isReadOnly)),
            .src("about:blank"),
            .custom(name: "loading", value: "eager")
        ) {}
        div(.id("nb-results"), .class("nb-results"), .hidden) {}
        div(
            .id("browser-runner-status"), .class("nb-status"), .role("status"),
            .custom(name: "aria-live", value: "polite"), .custom(name: "aria-atomic", value: "true"), .hidden
        ) {}
        for path in Self.scripts {
            script(.src(asset(path))) {}
        }
        script(
            .src(asset("/browser-runner.js")), .data("setup-id", value: testSetupID),
            .data("grading-mode", value: gradingMode)
        ) {}
    }

    /// The page scripts, in load order. `browser-runner.js` follows them with
    /// its own data attributes.
    private static let scripts = [
        "/notebook-preflight-core.js",
        "/notebook-preflight.js",
        "/grading-shared.js",
        "/r-grading-shared.js",
        "/lua-grading-shared.js",
        "/octave-grading-shared.js",
        "/runner-support-sources.js",
        "/grading-executors.js",
        "/notebook-core.js",
        "/notebook.js",
    ]

    private func asset(_ path: String) -> String {
        "\(path)?v=\(appVersion)"
    }

    /// The toolbar's one status notice, or Submit.
    @HTMLBuilder private var headerNotice: some HTML {
        if isStudentSolutionView {
            span(.class("nb-closed-notice")) {
                "Reference solution"
                if isReadOnly {
                    " — view only."
                }
            }
        } else if isTemplateView {
            span(.class("nb-closed-notice")) { "Editing the template — placeholders stand as written." }
        } else if showSubmit {
            if aiFeedbackNotice {
                span(.class("nb-closed-notice")) {
                    helpLink(
                        "https://github.com/JimWallace/Chickadee/blob/main/docs/ai-assisted-feedback.md#information-for-students",
                        "AI-assisted feedback is on ")
                }
                " "
            }
            button(.class("btn btn-primary"), .type(.button), .id("nb-submit")) { "Submit" }
        } else if isReadOnly {
            span(.class("nb-closed-notice")) { "This assignment is closed — view only." }
        } else if isClosed {
            span(.class("nb-closed-notice")) { "This assignment is closed to students — editable as course staff." }
        }
    }

    /// The failure panel, shown only when the editor failed: notebook-preflight.js
    /// hides the editor and reveals it. A slow boot uses the notice above
    /// instead (#2028). The js- classes are the hooks notebook-preflight.js
    /// rewrites; the standin-panel classes carry the look.
    private var fallbackPanel: some HTML {
        section(.id("js-nb-fallback"), .class("standin-panel"), .role("alert"), .hidden) {
            h2(.class("standin-panel-title js-nb-fallback-title")) { "Editor did not load" }
            p(.class("standin-panel-text js-nb-fallback-text")) {
                "To submit your work, upload your "
                code { ".ipynb" }
                " file."
            }
            p(.class("standin-panel-text")) {
                uploadInput(id: "nb-upload-file")
            }
            p(.class("standin-panel-text")) {
                "If the problem continues, "
                a(.id("nb-reset-editor-link"), .href("/reset-editor")) { "reset the notebook editor" }
                " or read the "
                helpLink(
                    "https://github.com/JimWallace/Chickadee/blob/main/docs/notebook-editor-help.md",
                    "notebook editor help ")
                "."
            }
            details {
                summary { "Diagnostic details" }
                pre(.id("js-nb-fallback-details")) {}
            }
        }
    }

    private func uploadInput(id: String) -> some HTML {
        input(
            .type(.file), .id(id), .accept(".ipynb,application/json"), .ariaLabel("Upload your .ipynb file"))
    }

    private func dismissButton(id: String, label: String) -> some HTML {
        button(.type(.button), .id(id), .class("btn action-btn"), .ariaLabel(label)) { "Dismiss" }
    }

    /// A link to the docs on GitHub, in a new tab, with the external icon.
    private func helpLink(_ url: String, _ text: String) -> some HTML {
        a(.href(url), .target(.blank), .rel("noopener noreferrer")) {
            text
            Icon("i-external")
            span(.class("visually-hidden")) { "(opens in a new tab)" }
        }
    }
}

extension NotebookBody {
    /// The body for a `NotebookContext`, the values the route and the
    /// workbench build.
    init(_ context: NotebookContext, appVersion: String) {
        self.init(
            testSetupID: context.testSetupID,
            notebookURL: context.notebookURL,
            jupyterLiteEditorURL: context.jupyterLiteEditorURL,
            downloadURL: context.downloadURL,
            gradingMode: context.gradingMode,
            browserUnsupported: context.browserUnsupported,
            showSubmit: context.showSubmit,
            isClosed: context.isClosed,
            isReadOnly: context.isReadOnly,
            canSaveToAssignment: context.canSaveToAssignment,
            fileKind: context.fileKind,
            isTemplateView: context.isTemplateView,
            viewToggleURL: context.viewToggleURL,
            solutionViewURL: context.solutionViewURL,
            isStudentSolutionView: context.isStudentSolutionView,
            workingCopyMtime: context.workingCopyMtime,
            embedded: context.embedded == true,
            aiFeedbackNotice: context.aiFeedbackNotice,
            appVersion: appVersion
        )
    }
}
