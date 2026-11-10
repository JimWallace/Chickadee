// APIServer/Services/SuiteAnchorResolution.swift
//
// The notebook cell each suite item belongs to (docs/notebook-guide.md,
// "Anchors"), as the staff surfaces report it: the workbench outline
// (`InstructorSuiteOutlineBuilder`) and MCP `get_suite`. One place picks the
// notebook that decides the anchors and maps a resolved `NotebookAnchor` to
// its reported form, so those two staff surfaces cannot disagree about a
// test's cell. The rules themselves are `NotebookTestAnchoring` in Core. The
// student guide (`NotebookGuideBuilder`) applies the same rules to the
// student's own personalized starter, so before a solution exists its cell
// can differ from the one reported here.

import Core
import Fluent
import Foundation

enum SuiteAnchorResolution {
    /// The definitions that decide the anchors: the solution's, or the
    /// starter's when there is no solution yet (the starter has the same
    /// headings and, usually, the same stubs). An empty scan when neither
    /// can be read, which leaves only pins and generator targets.
    static func notebookScan(
        assignment: APIAssignment, setup: APITestSetup, language: AssignmentLanguage?,
        db: any Database, testSetupsDirectory: String
    ) async -> NotebookDefinitionScan {
        let solutionData = try? await solutionNotebookData(
            for: assignment, setup: setup, db: db, testSetupsDirectory: testSetupsDirectory)
        let anchorData: Data?
        if let solutionData {
            anchorData = solutionData
        } else {
            anchorData = try? await notebookData(for: setup)
        }
        return anchorData.map { scanNotebookDefinitions($0, language: language) }
            ?? NotebookDefinitionScan(definitions: [], sections: [], codeCellIndices: [])
    }

    /// The anchor of `entry`, or nil when it links to no cell.
    ///
    /// - Parameter scriptSource: the entry's script, for a hand-written test.
    ///   Nil when it could not be read, which skips the script rule.
    static func anchor(
        for entry: TestSuiteEntry, in manifest: TestProperties, notebook: NotebookDefinitionScan,
        scriptSource: String?
    ) -> InstructorSuiteOutline.Anchor? {
        let request = NotebookTestAnchoring.request(for: entry, in: manifest, scriptSource: scriptSource)
        let resolved = NotebookTestAnchoring.resolve(request, solution: notebook)
        guard let name = resolved.name else { return nil }
        let kind: String
        switch resolved.kind {
        case .name: kind = notebook.definition(of: name)?.kind.rawValue ?? "name"
        case .section: kind = "section"
        case .unlinked: return nil
        }
        return InstructorSuiteOutline.Anchor(
            kind: kind, name: name, source: resolved.rule == .pinned ? "pinned" : "auto",
            ambiguous: resolved.ambiguous)
    }
}
