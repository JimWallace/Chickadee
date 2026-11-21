// Tests/APITests/Notebooks/NotebookBodyContextRenderTests.swift
//
// `NotebookBody` built from a `NotebookContext`, as the notebook route and the
// workbench build it, and rendered to HTML:
//
//   - a staff draft kept beside the stored notebook (#2925) shows the
//     "Saved version opened." notice with a download link to the backup, and
//     only when the context names both the file and its URL
//   - a student's own notebook draws the task outline and its own guide; the
//     workbench pane draws no outline, and a previewed student's guide wins
//   - the context's server-drive flag and definition patterns reach the
//     editor iframe

import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookBodyContextRenderTests {

    /// A staff authoring context, with the fields each test varies.
    private func context(
        showSubmit: Bool = false,
        embedded: Bool? = nil,
        previewGuideURL: String? = nil,
        serverDrive: Bool = false,
        definitionPatterns: [String] = [],
        draftBackupFileName: String? = nil,
        draftBackupURL: String? = nil
    ) -> NotebookContext {
        NotebookContext(
            testSetupID: "setup-nbctx",
            assignmentTitle: "Lab 4",
            notebookURL: "/testsetups/setup-nbctx/notebook/source?file=assignment&view=personalized&edit=1",
            jupyterLiteEditorURL:
                "/jupyterlite/notebooks/index.html?workspace=w&reset=&path=users/u/setup-nbctx/a.ipynb",
            downloadURL: nil,
            gradingMode: "browser",
            browserUnsupported: false,
            showSubmit: showSubmit,
            isClosed: false,
            isReadOnly: false,
            canSaveToAssignment: !showSubmit,
            fileKind: "assignment",
            isTemplateView: false,
            viewToggleURL: nil,
            solutionViewURL: nil,
            isStudentSolutionView: false,
            workingCopyMtime: 1_700_000_000,
            currentUser: nil,
            embedded: embedded,
            kernelLanguage: "Python",
            bootBird: nil,
            definitionPatterns: definitionPatterns,
            previewGuideURL: previewGuideURL,
            serverDrive: serverDrive,
            draftBackupFileName: draftBackupFileName,
            draftBackupURL: draftBackupURL
        )
    }

    private func render(_ context: NotebookContext) -> String {
        NotebookBody(context, appVersion: "9.9.9", csrfToken: "tok").render()
    }

    // MARK: - Draft backup notice (#2925)

    @Test func aKeptDraftShowsTheNoticeWithADownloadLinkToTheBackup() {
        let name = "a (unsaved draft 2026-11-20 10.15).ipynb"
        let url = "/jupyterlite/files/users/u/setup-nbctx/a%20(unsaved%20draft%202026-11-20%2010.15).ipynb"
        let html = render(context(serverDrive: true, draftBackupFileName: name, draftBackupURL: url))

        #expect(html.contains(#"id="nb-draft-backup-notice""#))
        #expect(html.contains("Saved version opened."))
        #expect(html.contains(" Your earlier edits are in "))
        #expect(html.contains(#"href="\#(url)""#), "the link points at the backup file")
        #expect(html.contains(#"download="\#(name)""#), "the download keeps the backup's own name")
        #expect(html.contains(">\(name)</a>"), "the link text names the backup file")
    }

    @Test func aBackupNameWithoutAURLShowsNoNotice() {
        let html = render(context(draftBackupFileName: "a (unsaved draft).ipynb", draftBackupURL: nil))
        #expect(!html.contains("nb-draft-backup-notice"))
        #expect(!html.contains("Saved version opened."))
    }

    @Test func noKeptDraftShowsNoNotice() {
        let html = render(context())
        #expect(!html.contains("nb-draft-backup-notice"))
        #expect(!html.contains("Saved version opened."))
        // The page still renders its fixed parts.
        #expect(html.contains(#"id="jl-frame""#))
        #expect(html.contains(#"id="nb-slow-notice""#))
    }

    // MARK: - Task outline and guide

    @Test func aStudentsOwnNotebookDrawsTheOutlineAndItsOwnGuide() {
        let html = render(context(showSubmit: true))
        #expect(html.contains(#"class="nb-workspace""#))
        #expect(html.contains(#"id="nb-outline""#))
        #expect(html.contains(#"data-guide-url="/testsetups/setup-nbctx/notebook-guide.json""#))
    }

    @Test func theWorkbenchPaneDrawsNoOutlineAndNoGuide() {
        let html = render(context(showSubmit: true, embedded: true))
        #expect(!html.contains("nb-workspace"))
        #expect(!html.contains(#"id="nb-outline""#))
        #expect(html.contains(#"data-guide-url="""#))
        #expect(html.contains("jl-frame-embedded"))
    }

    @Test func aStaffAuthoringCopyDrawsNoOutline() {
        let html = render(context(showSubmit: false))
        #expect(!html.contains(#"id="nb-outline""#))
        #expect(html.contains(#"data-guide-url="""#))
    }

    @Test func aPreviewedStudentsGuideWinsInThePane() {
        let guide = "/instructor/abc123/students/uuid-1/notebook-guide.json"
        let html = render(context(embedded: true, previewGuideURL: guide))
        #expect(html.contains(#"data-guide-url="\#(guide)""#))
        #expect(!html.contains(#"id="nb-outline""#), "a preview gives the guide, not the outline")
    }

    // MARK: - Iframe data attributes

    @Test func theServerDriveFlagAndDefinitionPatternsReachTheIframe() {
        let on = render(context(serverDrive: true, definitionPatterns: [#"^def (\w+)"#]))
        #expect(on.contains(#"data-server-drive="true""#))
        #expect(on.contains("data-definition-patterns="))
        #expect(on.contains("def ("), "the pattern is in the attribute")

        let off = render(context(serverDrive: false))
        #expect(off.contains(#"data-server-drive="false""#))
        #expect(off.contains(#"data-definition-patterns="[]""#))
    }
}
