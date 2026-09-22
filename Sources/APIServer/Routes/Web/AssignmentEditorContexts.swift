// APIServer/Routes/Web/AssignmentEditorContexts.swift
//
// Leaf view-context types for the assignment authoring flow (new / edit
// pages).  Split from the original `AssignmentContextTypes.swift`
// so each `Encodable` synthesis lives in its own translation unit.
//
// `NewAssignmentContext` (26 fields) and `EditAssignmentContext` (23) are
// the two largest contexts in the codebase; isolating them here means
// touching either one only recompiles this file (plus its one construction
// site).  Nesting is deferred — Leaf templates reference these fields
// flat via `#(field)`, so nesting would force a template-side rewrite.

import Core
import Fluent
import Foundation

struct NewAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentName: String
    let dueAt: String
    let startsAt: String
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
    /// The notebook-check form schema (`notebookCheckFormSchemaJSON()`),
    /// embedded as the `check-schema` seed.  Drives the generic
    /// schema-driven check editor — the per-kind field cards are rendered
    /// from this rather than hand-coded in the template.  Static across
    /// assignments.
    let checkSchemaJSON: String
    /// The assignment language's authoring facts (`authoringLanguageFactsJSON`),
    /// embedded as the `assignment-language-seed` script tag.
    ///
    /// The pattern-family editor had NO notion of language at all — it
    /// validated Python identifiers, parsed `True`/`False`/`None`, and echoed
    /// Python reprs on an R lab. This is the one channel that tells it which
    /// language it is editing; without it the JS could not gate on the language
    /// even if it wanted to.
    let assignmentLanguageJSON: String
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
    /// Drives `_suite-sections.leaf`, shared with the edit page. The block is
    /// identical between the two surfaces apart from where its per-section
    /// forms post and whether they carry `data-ck-inplace`, so those are the
    /// only things the partial takes.
    let sectionActionBase: String
    let sectionActionQuery: String
    let sectionFormsInPlace: Bool
    let requiredPlatform: String
    let requiredArchitecture: String
    let requiredLanguagesCSV: String
    let requiredCapabilitiesCSV: String
    let detectedLanguages: [String]
    let detectedCapabilities: [String]
    /// The required Language select's options, same builder the edit page
    /// uses. Declared at creation so nothing downstream has to derive it.
    let assignmentLanguageOptions: [AssignmentLanguageOption]
    /// "C++ or Racket" — the languages whose assignments are upload-only,
    /// derived so the fine print cannot name fewer of them than the rule
    /// enforces. It named only C++ for the whole of Racket's existence.
    let uploadOnlyLanguagesProse: String = LanguageProse.uploadOnlyDisplayNames
    /// "python, r, lua, octave, cpp, racket" — the required-Languages input's
    /// placeholder, derived for the same reason the select above it is.
    let languageTokensCSV: String = LanguageProse.allTokensCSV
    let detectedLanguagesCSV: String
    let detectedCapabilitiesCSV: String
    let notice: String?
    let error: String?
}

struct NewAssignmentNotebookContext: Encodable {
    let name: String
    let editURL: String
}

/// The assignment workbench shell (`workbench.leaf`).  Deliberately thin: the
/// shell renders no assignment content, only the frame around iframes that
/// each load an existing page.  Everything here is either an identifier the
/// page JS keys on or a URL for one of those iframes.
struct AssignmentWorkbenchContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let testSetupID: String
    let assignmentTitle: String
    /// The left pane's content, rendered inline by
    /// `#extend("_assignment-edit-body", edit)`.
    ///
    /// Nested rather than flattened so the *same* partial serves the
    /// standalone `/edit` page, where it resolves against a bare
    /// `EditAssignmentContext`. LeafKit binds a partial against a sub-object
    /// when it is passed as the extend's second parameter, so one copy of the
    /// markup answers to both — and `embedded`, which means different things
    /// to the two halves, stays unambiguous because each half reads its own.
    let edit: EditAssignmentContext
    /// The right pane's content, rendered inline by
    /// `#extend("_notebook-body", notebook)`. Built by
    /// `WebRoutes.workbenchNotebookContext`, the same builder the standalone
    /// notebook page uses.
    ///
    /// **Optional, and that is load-bearing.** Building it reads a notebook off
    /// disk, which throws `.notFound` for an assignment that has none yet — a
    /// real state, since an assignment can be created and its metadata and
    /// suite edited before any notebook is uploaded. When the workbench
    /// composed the notebook as an iframe, a missing notebook failed *inside*
    /// the frame and left the edit half usable; inlining it would have made
    /// that failure 404 the whole authoring page. So the pane degrades to a
    /// placeholder instead and the edit half stays reachable.
    let notebook: NotebookContext?
    /// `{"<file>:<view>": "<url>"}` for every combination that exists, as a
    /// JSON object the page embeds and the tab handlers look up.  A lookup
    /// table rather than one iframe per entry: there is only ever one notebook
    /// document alive, so these are destinations, not panes.
    ///
    /// `view=` is always explicit in each URL — `resolveNotebookViewMode`
    /// defaults staff to the template on a notebook that carries placeholders,
    /// so omitting it would make "Assignment" mean the template on a
    /// personalized lab and the rendering on every other one.
    let notebookPaneURLsJSON: String
    /// True when the assignment has a reference solution.  `false` omits the
    /// Solution tab rather than disabling it — matching how the edit page
    /// omits `solutionNotebookEditURL`.
    let hasSolution: Bool
    /// Per-file: whether the stored notebook still carries `{{name}}`, i.e.
    /// whether its template and rendered views actually differ.  When they do
    /// not, the two panes would be byte-identical and the view control is
    /// noise, so it is not rendered.
    let assignmentHasTemplateView: Bool
    let solutionHasTemplateView: Bool
    /// Escape hatch back to the full-width single-page editor.
    let standaloneEditURL: String
    /// Drops `.main`'s reading-column cap and gutters — the workbench sizes
    /// itself to the viewport and scrolls inside its panes.
    let fullBleed: Bool = true
    /// Loads `inplace-forms.js`, which fetches this page's form POSTs instead
    /// of letting them navigate.
    ///
    /// Load-bearing, not cosmetic. The edit half's writes — save, secret
    /// reveal, create-solution, suite-section add/rename/delete, support-file
    /// upload/delete — all answer with a redirect. In one document a
    /// navigation would tear down the Pyodide kernel in the other half, which
    /// is the whole failure this page was merged to avoid. When the halves
    /// were iframes the frame absorbed it; now nothing does.
    let inPlaceForms: Bool = true
}

struct EditAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let testSetupID: String
    let assignmentName: String
    let dueAt: String
    let startsAt: String
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
    /// The notebook-check form schema (`notebookCheckFormSchemaJSON()`),
    /// embedded as the `check-schema` seed.  Drives the generic
    /// schema-driven check editor.  Static across assignments.
    let checkSchemaJSON: String
    /// The assignment language's authoring facts (`authoringLanguageFactsJSON`),
    /// embedded as the `assignment-language-seed` script tag.
    ///
    /// The pattern-family editor had NO notion of language at all — it
    /// validated Python identifiers, parsed `True`/`False`/`None`, and echoed
    /// Python reprs on an R lab. This is the one channel that tells it which
    /// language it is editing; without it the JS could not gate on the language
    /// even if it wanted to.
    let assignmentLanguageJSON: String
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
    /// Drives `_suite-sections.leaf`, shared with the create page. See the
    /// matching fields on `NewAssignmentContext`.
    let sectionActionBase: String
    let sectionActionQuery: String
    let sectionFormsInPlace: Bool
    /// Slice 1 — assignment-scope global inputs, rendered as the same
    /// `name + valueJSON` shape section variables use.  The new
    /// "Global Inputs" panel at the top of the edit page iterates this
    /// list to seed its initial rows.  Empty when no globals declared.
    let globalVariableRows: [SuiteSectionVariableShellRow]
    /// The condition signals the achievements editor offers, in declaration
    /// order.  The condition-builder's signal dropdown renders from this list —
    /// see `AchievementSignalPresentation`.
    let achievementSignalOptions: [AchievementSignalOption]
    /// The "Ranked by" select's options, in `RecordDimension.allCases` order —
    /// see `RecordDimensionPresentation`.
    let recordDimensionOptions: [RecordDimensionOption]
    let brightspaceSyncEnabled: Bool
    let brightspaceGradeObjectID: String?
    /// "notebook" | "uploadOnly" from the manifest — renders the Submission
    /// select's current value in the name/due-date edit block.
    let submissionMode: String
    /// The Language select's options, in `AssignmentLanguage.allCases` order
    /// behind the "detect automatically" entry. Built from `allCases` rather
    /// than written out in the template so a sixth language needs no Leaf edit —
    /// the same discovered-not-enumerated rule the kernel-alias generator and
    /// the runner's capability probe follow.
    let assignmentLanguageOptions: [AssignmentLanguageOption]
    /// "C++ or Racket" — see the identically-named field on
    /// `NewAssignmentContext`. Both pages carry the same fine print and both
    /// had gone stale the same way.
    let uploadOnlyLanguagesProse: String = LanguageProse.uploadOnlyDisplayNames
    /// Everything the Class activity select and the Activity section render —
    /// see `ActivityEditFacts`.
    let activity: ActivityEditFacts
    /// The per-assignment secret-reveal toggle: whether students may spend
    /// their one reveal token here.  Renders the "Student Options" checkbox.
    let secretRevealEnabled: Bool
    /// The per-assignment solution-reveal policy: true when
    /// `solutionVisibility` is `afterDue`.  Renders the second "Student
    /// Options" checkbox.
    let solutionVisibilityAfterDue: Bool
    /// The advisory passing threshold (1...100), or nil when the passing
    /// concept is off.  Renders the third "Student Options" control.
    let passingThresholdPercent: Int?
    /// Assignment-wide default per-test execution limit (seconds) from the
    /// manifest (`TestProperties.timeLimitSeconds`).  Renders the editable
    /// "Default time limit" input in the Test Suite header, saved live via
    /// `PUT /instructor/:assignmentID/time-limit` (#979).
    let timeLimitSeconds: Int
    let notice: String?
    let error: String?
    /// True when this page is being rendered into the left pane of the
    /// assignment workbench (`GET /instructor/:assignmentID/workbench`)
    /// rather than as the standalone edit page.  `base.leaf` reads it to
    /// suppress the site chrome, and the template reads it to drop the
    /// "Open workbench" link (the workbench must not link to itself).
    /// `nil` on the standalone `/edit` render.
    let embedded: Bool?
}

/// One entry in the edit page's Language select.
struct AssignmentLanguageOption: Encodable {
    /// An `AssignmentLanguage` raw value, or "" for the derive-it entry.
    let value: String
    let label: String
    let selected: Bool

    /// Builds the whole list for an assignment whose manifest records
    /// `recorded` (nil when no language is recorded).
    ///
    /// The first entry is a DECLARATION that the assignment has no language —
    /// a plain shell-script suite — not a request to go and detect one. That
    /// distinction is the point of the whole change: an author picking it is
    /// answering the question, so nothing downstream has to guess afterwards.
    /// It doubles as the way to undo a declaration, since
    /// `AssignmentLanguage.resolve` treats a recorded value as authoritative
    /// over the notebook and the suite.
    static func options(recorded: String?) -> [AssignmentLanguageOption] {
        let normalized = recorded?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noLanguage = AssignmentLanguageOption(
            value: noLanguageChoice,
            label: "None — plain shell scripts",
            selected: normalized == nil || AssignmentLanguage(rawValue: normalized ?? "") == nil
        )
        return [noLanguage]
            + AssignmentLanguage.allCases.map { language in
                AssignmentLanguageOption(
                    value: language.rawValue,
                    label: language.displayName,
                    selected: normalized == language.rawValue
                )
            }
    }
}

/// The edit page's class-activity facts (docs/class-activities.md), nested
/// under one key so the page context stays within its body budget. Every
/// field is a plain value because Leaf resolves no Swift properties.
struct ActivityEditFacts: Encodable {
    /// The "Class activity" select's options: "None" first, then every
    /// `ActivityKind` in `allCases` order — derived, never written out.
    let kindOptions: [ActivityKindOption]
    /// True once a student has submitted: the select renders disabled and the
    /// fine print says why (`ActivityAuthoring.kindLockedMessage`'s rule).
    let locked: Bool
    /// True when the manifest carries an activity block; gates the Activity
    /// section. Explicit Bool, as every Leaf gate here is.
    let isSet: Bool
    let kindLabel: String
    let summary: String
    let leaderboardVisible: Bool
    let leaderboardURL: String
    /// True when the kind stages a bundled bot, so the Opponent file picker
    /// renders. False for a kind with no opponent and for an ordinary
    /// assignment.
    let needsOpponentFile: Bool
    /// True when a bot is chosen; the picker's fine print says so either way,
    /// since until one is chosen nothing is staged for the script to play.
    let opponentFileChosen: Bool
    /// The Opponent file select: "None chosen" first, then every support file
    /// of the setup (the same listing `get_support_files` reports), marking
    /// the stored one selected.
    let opponentFileOptions: [OpponentFileOption]
    /// The live-session window's bounds as a `datetime-local` input reads
    /// them — "2026-09-22T14:00", local time, no zone — or "" when unset.
    ///
    /// A different spelling from the stored ISO-8601, and it has to be: the
    /// input type refuses a value carrying a zone, and rendering the stored
    /// string straight into it leaves the field blank with no error anywhere.
    /// Rendered by `dueAtLocalInputString` and read back by `parseDueDate` —
    /// the one renderer and the one parser this UI has for an
    /// instructor-entered local datetime, which is the #1118 rule.
    let windowOpensAtLocal: String
    let windowClosesAtLocal: String

    static func make(setup: APITestSetup, on db: any Database) async throws -> ActivityEditFacts {
        let activity = setup.decodedManifest()?.activity
        let testSetupID = setup.id ?? ""
        let needsOpponentFile = activity?.takesAnOpponentFile == true
        return ActivityEditFacts(
            kindOptions: ActivityKindOption.options(current: activity?.kind),
            locked: try await ActivityAuthoring.hasStudentSubmissions(setup: setup, on: db),
            isSet: activity != nil,
            kindLabel: activity?.kind.displayName ?? "",
            summary: activity?.kind.summary ?? "",
            leaderboardVisible: activity?.leaderboardVisibleToStudents == true,
            leaderboardURL: "/testsetups/\(testSetupID)/leaderboard",
            needsOpponentFile: needsOpponentFile,
            opponentFileChosen: activity?.opponentFile != nil,
            opponentFileOptions: needsOpponentFile
                ? OpponentFileOption.options(
                    supportFiles: await currentSupportFileNames(setup: setup),
                    current: activity?.opponentFile)
                : [],
            windowOpensAtLocal: dueAtLocalInputString(activity?.window?.opensAt),
            windowClosesAtLocal: dueAtLocalInputString(activity?.window?.closesAt))
    }
}

/// One entry in the Activity section's "Opponent file" select.
struct OpponentFileOption: Encodable {
    /// A support filename, or "" for none.
    let value: String
    let label: String
    let selected: Bool

    /// The empty choice followed by every support file. A stored file the
    /// setup no longer contains (deleted after it was chosen) is listed too,
    /// marked selected, so the page shows what the worker will fail on rather
    /// than silently showing "None chosen".
    static func options(supportFiles: [String], current: String?) -> [OpponentFileOption] {
        var names = supportFiles
        if let current, !names.contains(current) { names.append(current) }
        return [OpponentFileOption(value: "", label: "None chosen", selected: current == nil)]
            + names.map { OpponentFileOption(value: $0, label: $0, selected: $0 == current) }
    }
}

/// One entry in the edit page's "Class activity" select.
struct ActivityKindOption: Encodable {
    /// An `ActivityKind` raw value, or `SetActivityTool.noActivityChoice`.
    let value: String
    let label: String
    let selected: Bool

    /// "None" followed by every kind, marking the stored one selected.
    static func options(current: ActivityKind?) -> [ActivityKindOption] {
        [ActivityKindOption(value: SetActivityTool.noActivityChoice, label: "None", selected: current == nil)]
            + ActivityKind.allCases.map { kind in
                ActivityKindOption(value: kind.rawValue, label: kind.displayName, selected: kind == current)
            }
    }
}
