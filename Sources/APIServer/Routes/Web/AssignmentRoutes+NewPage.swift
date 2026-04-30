// APIServer/Routes/Web/AssignmentRoutes+NewPage.swift
//
// Context-building helpers for `GET /instructor/new`
// (`AssignmentRoutes.newAssignmentPage`).  Split out per #443: the original
// handler interleaved ~190 lines of nested optional chains, draft notebook
// resolution, JSON encoding, and view-context assembly.  Each step is now a
// focused free helper on `AssignmentRoutes`; the handler just sequences
// them and renders.

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - Notebook context

    /// Builds the assignment-notebook block (filename + edit URL) shown at
    /// the top of `assignment-new.leaf`.  Returns `nil` when no draft setup
    /// exists yet, or when the setup has no `notebookPath`.
    func newAssignmentNotebookContext(
        setup: APITestSetup?,
        storedState: NewAssignmentDraftFormState
    ) -> NewAssignmentNotebookContext? {
        guard let setup, let notebookPath = setup.notebookPath else { return nil }
        let name = storedState.assignmentNotebookName
            ?? URL(fileURLWithPath: notebookPath).lastPathComponent
        let titleParam = storedState.assignmentName.isEmpty ? "Assignment Notebook" : storedState.assignmentName
        return NewAssignmentNotebookContext(
            name: name,
            editURL: "/testsetups/\(setup.id!)/notebook?title=\(urlEncode(titleParam))"
        )
    }

    /// Builds the solution-notebook block — falls back to the materialised
    /// per-user working copy when no flat solution file exists yet.  Returns
    /// `nil` when neither a draft path nor a user working copy is on disk.
    func newAssignmentSolutionNotebookContext(
        req: Request,
        userID: UUID,
        setup: APITestSetup?,
        storedState: NewAssignmentDraftFormState
    ) -> NewAssignmentNotebookContext? {
        guard let setup else { return nil }
        let draftPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory,
            setupID: setup.id!
        )
        let fallbackData = draftNotebookData(
            req: req,
            setupID: setup.id!,
            userID: userID,
            fileKind: .solution,
            fallbackPath: draftPath
        )
        guard fallbackData != nil else { return nil }
        let name = storedState.solutionNotebookName
            ?? URL(fileURLWithPath: draftPath).lastPathComponent
        return NewAssignmentNotebookContext(
            name: name,
            editURL: "/testsetups/\(setup.id!)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))"
        )
    }

    // MARK: - Suite + support rows

    /// Returns the support-file rows (tier == "support") with their `url`
    /// rebuilt against the draft-scoped download endpoint.  The base
    /// `editableSuiteRowsForSetup` helper sets `url: "#"` because it doesn't
    /// know the draft's id.
    func newAssignmentSupportFileRows(
        setup: APITestSetup?,
        suiteRows: [EditableSuiteRow]
    ) -> [EditableSuiteRow] {
        guard let setup, let draftID = setup.id else { return [] }
        return suiteRows
            .filter { $0.tier == "support" }
            .map { row in
                EditableSuiteRow(
                    name: row.name,
                    url: "/instructor/new/draft/files/item?draftID=\(urlEncode(draftID))&name=\(urlEncode(row.name))",
                    isTest: row.isTest,
                    tier: row.tier,
                    order: row.order,
                    dependsOn: row.dependsOn,
                    points: row.points,
                    displayName: row.displayName
                )
            }
    }

    /// Auto-detects required runner languages + capabilities from the
    /// draft's notebooks.  Returns an empty suggestion bundle when no draft
    /// exists yet.
    func newAssignmentRequirementSuggestions(
        req: Request,
        userID: UUID,
        setup: APITestSetup?
    ) -> DraftRequirementSuggestions {
        guard let setup else {
            return DraftRequirementSuggestions(languages: [], capabilities: [])
        }
        let assignmentData = draftNotebookData(
            req: req,
            setupID: setup.id!,
            userID: userID,
            fileKind: .assignment,
            fallbackPath: setup.notebookPath
        )
        let solutionData = draftNotebookData(
            req: req,
            setupID: setup.id!,
            userID: userID,
            fileKind: .solution,
            fallbackPath: draftSolutionNotebookPath(
                testSetupsDirectory: req.application.testSetupsDirectory,
                setupID: setup.id!
            )
        )
        return detectRequirementSuggestions(
            assignmentNotebookData: assignmentData,
            solutionNotebookData: solutionData,
            setup: setup
        )
    }

    // MARK: - JSON seeds

    /// Returns the JSON-quoted draft id (`"abcd1234"`) — or `null` when no
    /// draft exists yet.  The page's pattern-family editor parses this once
    /// at boot to decide whether to wire its draft-scoped endpoints.
    func newAssignmentDraftIDJSON(setup: APITestSetup?) -> String {
        guard let id = setup?.id else { return "null" }
        let encoder = JSONEncoder()
        return (try? String(data: encoder.encode(id), encoding: .utf8)) ?? "null"
    }

    /// Returns `manifest.patternFamilies` as a JSON array literal — `[]`
    /// when the draft is missing or its manifest can't be decoded.
    func newAssignmentPatternFamiliesJSON(setup: APITestSetup?) -> String {
        manifestArrayJSON(setup: setup) { $0.patternFamilies }
    }

    /// Returns `manifest.notebookChecks` as a JSON array literal — `[]`
    /// when the draft is missing or its manifest can't be decoded.
    func newAssignmentNotebookChecksJSON(setup: APITestSetup?) -> String {
        manifestArrayJSON(setup: setup) { $0.notebookChecks }
    }

    /// Helper: serialise an `Encodable` slice of `TestProperties` to JSON,
    /// returning `"[]"` on any failure.
    private func manifestArrayJSON<T: Encodable>(
        setup: APITestSetup?,
        _ extract: (TestProperties) -> [T]
    ) -> String {
        guard let setup,
              let manifestData = setup.manifest.data(using: .utf8),
              let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
        else { return "[]" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(extract(props)), encoding: .utf8)) ?? "[]"
    }

    /// Suite-editor seed JSON.  `suiteStateJSON` already handles the
    /// no-draft case (returns `{"items":[]}`); this wrapper just supplies
    /// the same payload when no draft exists.
    func newAssignmentSuiteStateSeedJSON(setup: APITestSetup?) -> String {
        setup.map { suiteStateJSON(fromManifest: $0.manifest) } ?? #"{"items":[]}"#
    }

    /// Server-rendered section-shell rows.  Falls back to a single
    /// "Ungrouped" placeholder when no draft exists so the suite editor
    /// renders before the instructor uploads a notebook.
    func newAssignmentSuiteSectionShellRows(setup: APITestSetup?) -> [SuiteSectionShellRow] {
        setup.map { suiteSectionShellRows(fromManifest: $0.manifest) }
            ?? [SuiteSectionShellRow(
                sectionID: "",
                name: "",
                isUngrouped: true,
                variables: [],
                hasVariables: false
            )]
    }

    // MARK: - Section picker

    /// Loads the per-course sections used to populate the section
    /// `<select>` on the new-assignment page.  Returns `[]` when no course
    /// is active.
    func loadNewAssignmentSectionPicker(
        req: Request,
        activeCourseUUID: UUID?
    ) async throws -> [CourseSectionRow] {
        guard let activeCourseUUID else { return [] }
        return try await APICourseSection.query(on: req.db)
            .filter(\.$courseID == activeCourseUUID)
            .sort(\.$sortOrder, .ascending)
            .all()
            .map { s in
                CourseSectionRow(
                    sectionID: s.id?.uuidString ?? "",
                    name: s.name,
                    defaultGradingMode: s.defaultGradingMode,
                    sortOrder: s.sortOrder,
                    rows: []
                )
            }
    }
}
