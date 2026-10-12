// Tests/APITests/ElementaryPageFixtures+Workbench.swift
//
// The assignment workbench, rendered for ElementaryPageGuardTests: the edit
// half beside a notebook (the starter, the solution template), and beside the
// stand-in an assignment with no notebook yet shows.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var workbenchPages: [ElementaryPageFixture] {
        [workbenchPage]
    }

    static var workbenchPage: ElementaryPageFixture {
        func render(rich: Bool, notebook: NotebookBody?, templates: Bool) -> String {
            WorkbenchPage(
                page: page(currentUser: signedInAdmin), assignmentID: "abc123", testSetupID: "t1",
                assignmentTitle: rich ? "Lab 2" : "Assignment", edit: EditorSamples.edit(rich: rich, embedded: true),
                notebook: notebook,
                notebookPaneURLsJSON:
                    #"{"assignment:personalized":"/instructor/abc123/workbench?file=assignment&view=personalized"}"#,
                assignmentHasTemplateView: templates, solutionHasTemplateView: templates
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "WorkbenchPage",
            archetype: .fullBleedApp,
            renders: [
                render(rich: false, notebook: nil, templates: false),
                render(
                    rich: true,
                    notebook: notebookBody(
                        NotebookBodyOptions(
                            downloadURL: "/instructor/abc123/files/notebook", canSave: true, embedded: true)),
                    templates: false),
                render(
                    rich: true,
                    notebook: notebookBody(
                        NotebookBodyOptions(
                            isClosed: true, canSave: true, fileKind: "solution", isTemplateView: true,
                            viewToggleURL: "/t",
                            embedded: true)),
                    templates: true),
            ]
        )
    }
}
