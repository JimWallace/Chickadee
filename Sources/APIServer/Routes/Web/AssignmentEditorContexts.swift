// APIServer/Routes/Web/AssignmentEditorContexts.swift
//
// Leaf view-context types for the assignment authoring flow (validate /
// new / edit pages).  Split from the original `AssignmentContextTypes.swift`
// so each `Encodable` synthesis lives in its own translation unit.
//
// `NewAssignmentContext` (26 fields) and `EditAssignmentContext` (23) are
// the two largest contexts in the codebase; isolating them here means
// touching either one only recompiles this file (plus its one construction
// site).  Nesting is deferred — Leaf templates reference these fields
// flat via `#(field)`, so nesting would force a template-side rewrite.

import Foundation

struct ValidateContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let setupID: String
    let title: String
    let suiteCount: Int
    let dueAt: String?
}

struct NewAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentName: String
    let dueAt: String
    let sections: [CourseSectionRow]  // available sections for the section picker
    let preselectedSectionID: String  // from ?sectionID= query param
    let draftID: String?
    /// JSON-encoded `draftID` (quoted string or `null`) for embedding in an
    /// inline script via `#rawJSON(...)`.  The pattern-family editor uses
    /// this to skip initialisation before a solution notebook has been
    /// uploaded (no draft exists yet → nothing to scan).
    let draftIDJSON: String
    let assignmentNotebook: NewAssignmentNotebookContext?
    let solutionNotebook: NewAssignmentNotebookContext?
    let suiteRows: [EditableSuiteRow]
    let hasSuiteRows: Bool
    /// Files in the test setup zip that aren't tests (tier == "support") —
    /// data fixtures (CSVs, JSON, etc.) bundled with the assignment.
    /// Rendered as their own group at the top of the page alongside the
    /// starter and solution notebooks (parity with the edit page).  Each
    /// row's `url` points at the draft-scoped download endpoint
    /// (`/instructor/new/draft/files/item?draftID=…&name=…`).
    let supportFileRows: [EditableSuiteRow]
    /// Pattern families persisted in the draft's manifest, rendered as JSON
    /// for the `pattern-families-seed` script tag.  `[]` when the draft has
    /// no families (or no draft exists yet).
    let patternFamiliesJSON: String
    /// Notebook checks persisted in the draft's manifest, rendered as JSON
    /// for the `notebook-checks-seed` script tag (parity PR 2 of #433).
    /// `[]` when the draft has none (or no draft exists yet).  The check
    /// editor module parses this once at page load to seed its in-memory
    /// state; every subsequent save replaces it via `PUT /draft/checks`.
    let notebookChecksJSON: String
    /// Full reconciled `GET /suite` payload embedded as JSON.  Same shape
    /// the edit page emits — `suite-table.js` parses it once at page load
    /// as the initial state of the unified items list, and every subsequent
    /// mutation is a PUT whose response replaces the local copy.  Empty
    /// `{"items":[]}` when no draft exists yet.
    let suiteStateJSON: String
    /// Server-rendered shell rows for the v0.4.96 sectioned suite layout
    /// — one row per named section plus a trailing "Ungrouped" block.
    /// Drives the `#for(sec in suiteSectionRows)` loop in
    /// `assignment-new.leaf` (parity with the edit page).  Always returns
    /// at least the Ungrouped block so the suite editor renders even
    /// before a draft has been created.
    let suiteSectionRows: [SuiteSectionShellRow]
    let requiredPlatform: String
    let requiredArchitecture: String
    let requiredLanguagesCSV: String
    let requiredCapabilitiesCSV: String
    let detectedLanguages: [String]
    let detectedCapabilities: [String]
    let detectedLanguagesCSV: String
    let detectedCapabilitiesCSV: String
    let notice: String?
    let error: String?
}

struct NewAssignmentNotebookContext: Encodable {
    let name: String
    let editURL: String
}

struct EditAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let testSetupID: String
    let assignmentName: String
    let dueAt: String
    let currentAssignmentFile: String
    let currentAssignmentURL: String
    let assignmentNotebookEditURL: String
    let currentSolutionFile: String?
    let currentSolutionURL: String?
    let solutionNotebookEditURL: String?
    let existingSuiteRows: [EditableSuiteRow]
    /// Files in the test setup zip that aren't tests (tier == "support").
    /// Surface as their own group at the top of the page alongside the
    /// starter and solution notebooks so instructors can see the data
    /// fixtures bundled with the assignment without scrolling through
    /// the test suite.  Same `EditableSuiteRow` shape as the test rows;
    /// rendered with no tier/points columns.
    let supportFileRows: [EditableSuiteRow]
    /// Pattern-family rows shown alongside raw scripts in the suite table.
    /// Generated `.py` entries they produce are filtered out of
    /// `existingSuiteRows` — the family row represents them collectively.
    let familyRows: [FamilySuiteRow]
    /// Pattern families currently defined on this assignment, rendered as a
    /// JSON array.  The editor JS parses it to seed the in-page family list.
    let patternFamiliesJSON: String
    /// Notebook checks currently defined on this assignment, rendered as a
    /// JSON array.  The editor JS parses it to seed the in-page check list.
    /// Empty `[]` for assignments with no checks (the common case until
    /// instructors start using the new editor).
    let notebookChecksJSON: String
    /// Full reconciled `GET /suite` payload embedded as JSON.  The editor JS
    /// parses it once at page load as the initial state of the unified
    /// items list; every subsequent mutation is a PUT whose response
    /// replaces this state.
    let suiteStateJSON: String
    /// Server-rendered shell rows for the suite-sections view (v0.4.98).
    /// One entry per named section (`isUngrouped = false`) in authored
    /// order, plus one trailing `isUngrouped = true` block if any item
    /// currently has no `sectionID` or there are no sections at all.  The
    /// template uses these to render the `.section-block` + `<tbody
    /// data-section-id>` shells that `suite-table.js` populates.
    let suiteSectionRows: [SuiteSectionShellRow]
    /// Slice 1 — assignment-scope global inputs, rendered as the same
    /// `name + valueJSON` shape section variables use.  The new
    /// "Global Inputs" panel at the top of the edit page iterates this
    /// list to seed its initial rows.  Empty when no globals declared.
    let globalVariableRows: [SuiteSectionVariableShellRow]
    let brightspaceSyncEnabled: Bool
    let brightspaceGradeObjectID: String?
    let notice: String?
    let error: String?
}
