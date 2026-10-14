// Tests/APITests/ElementaryPageFixtures+Workbench.swift
//
// The assignment workbench, rendered for ElementaryPageGuardTests: the edit
// half beside a notebook (the starter, the solution template), and beside the
// stand-in an assignment with no notebook yet shows.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var workbenchPages: [ElementaryPageFixture] {
        [workbenchPage]
    }

    static var workbenchPage: ElementaryPageFixture {
        typealias Case = (rich: Bool, notebook: NotebookBody?, templates: Bool)
        let host = page(currentUser: signedInAdmin)
        func render(_ item: Case) -> String {
            WorkbenchPage(
                page: host, assignmentID: "abc123", testSetupID: "t1",
                assignmentTitle: item.rich ? "Lab 2" : "Assignment",
                edit: EditorSamples.edit(rich: item.rich, embedded: true),
                notebook: item.notebook,
                notebookPaneURLsJSON:
                    #"{"assignment:personalized":"/instructor/abc123/workbench?file=assignment&view=personalized"}"#,
                assignmentHasTemplateView: item.templates, solutionHasTemplateView: item.templates
            ).render()
        }
        /// The two panes' bodies, rendered on their own.
        func bodies(_ item: Case) -> [String] {
            [EditorSamples.body(EditorSamples.edit(rich: item.rich, embedded: true), page: host)]
                + (item.notebook.map { [$0.render()] } ?? [])
        }
        let cases: [Case] = [
            (rich: false, notebook: nil, templates: false),
            (
                rich: true,
                notebook: notebookBody(
                    NotebookBodyOptions(downloadURL: "/instructor/abc123/files/notebook", canSave: true, embedded: true)
                ),
                templates: false
            ),
            (
                rich: true,
                notebook: notebookBody(
                    NotebookBodyOptions(
                        isClosed: true, canSave: true, fileKind: "solution", isTemplateView: true, viewToggleURL: "/t",
                        embedded: true)),
                templates: true
            ),
        ]
        return ElementaryPageFixture(
            typeName: "WorkbenchPage",
            archetype: .fullBleedApp,
            renders: cases.map(render),
            isExemplar: true,
            bodies: cases.map(bodies)
        )
    }
}
