// Tests/APITests/ElementaryPageFixtures+Notebook.swift
//
// The notebook editor page (the "Notebook" group of the Leaf-to-Elementary
// migration), rendered for ElementaryPageGuardTests: each toolbar notice, the
// staff controls, and the embedded workbench-pane rendering.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var notebookPages: [ElementaryPageFixture] {
        [notebookPage]
    }

    /// The toolbar state a notebook render varies, for `notebookBody`.
    struct NotebookBodyOptions {
        var downloadURL: String?
        var browserUnsupported = false
        var showSubmit = false
        var isClosed = false
        var isReadOnly = false
        var canSave = false
        var fileKind = "assignment"
        var isTemplateView = false
        var viewToggleURL: String?
        var solutionViewURL: String?
        var isStudentSolutionView = false
        var embedded = false
        var aiFeedbackNotice = false
    }

    static func notebookBody(_ options: NotebookBodyOptions) -> NotebookBody {
        NotebookBody(
            testSetupID: "setup-1",
            notebookURL: "/testsetups/setup-1/notebook/source?file=\(options.fileKind)&view=personalized",
            jupyterLiteEditorURL: "/jupyterlite/notebooks/index.html?workspace=w&reset=&path=users/u/setup-1/a.ipynb",
            downloadURL: options.downloadURL,
            gradingMode: "browser",
            browserUnsupported: options.browserUnsupported,
            showSubmit: options.showSubmit,
            isClosed: options.isClosed,
            isReadOnly: options.isReadOnly,
            canSaveToAssignment: options.canSave,
            fileKind: options.fileKind,
            isTemplateView: options.isTemplateView,
            viewToggleURL: options.viewToggleURL,
            solutionViewURL: options.solutionViewURL,
            isStudentSolutionView: options.isStudentSolutionView,
            workingCopyMtime: 1_700_000_000,
            embedded: options.embedded,
            aiFeedbackNotice: options.aiFeedbackNotice,
            appVersion: "0.0.0"
        )
    }

    static var notebookPage: ElementaryPageFixture {
        func render(_ options: NotebookBodyOptions) -> String {
            NotebookPage(page: page(currentUser: signedInAdmin), notebook: notebookBody(options)).render()
        }
        return ElementaryPageFixture(
            typeName: "NotebookPage",
            archetype: .bodyPartialShim,
            renders: [
                render(
                    NotebookBodyOptions(showSubmit: true, solutionViewURL: "/testsetups/setup-1/notebook?file=solution")
                ),
                render(NotebookBodyOptions(showSubmit: true, aiFeedbackNotice: true)),
                render(NotebookBodyOptions(browserUnsupported: true, isClosed: true, isReadOnly: true)),
                render(NotebookBodyOptions(isReadOnly: true, isStudentSolutionView: true)),
                render(
                    NotebookBodyOptions(
                        downloadURL: "/instructor/a1/files/notebook", isClosed: true, canSave: true,
                        fileKind: "solution", viewToggleURL: "/testsetups/setup-1/notebook?file=solution&view=template"
                    )),
                render(
                    NotebookBodyOptions(
                        canSave: true, isTemplateView: true,
                        viewToggleURL: "/testsetups/setup-1/notebook?file=assignment&view=personalized")),
                render(
                    NotebookBodyOptions(
                        downloadURL: "/instructor/a1/files/notebook", canSave: true, viewToggleURL: "/t",
                        embedded: true)),
            ]
        )
    }
}
