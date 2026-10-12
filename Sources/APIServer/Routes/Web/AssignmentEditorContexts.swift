// APIServer/Routes/Web/AssignmentEditorContexts.swift
//
// View-context types for the assignment authoring flow (new / edit pages).
// Split from the original `AssignmentContextTypes.swift` so each `Encodable`
// synthesis lives in its own translation unit.
//
// `EditAssignmentContext` feeds `AssignmentEditBody`, which both the
// standalone edit page and the workbench's left pane render.

import Core
import Fluent
import Foundation

/// One notebook on the Create Assignment page (`AssignmentNewPage`).
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
    /// Drive `SuiteSections` (and `_suite-sections.leaf`), shared with the
    /// create page: where the per-section forms post, and whether they carry
    /// `data-ck-inplace`.
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
    /// The GitHub submission checkbox (docs/github-submissions.md slice 3);
    /// nil hides it, because no GitHub App is registered or the assignment is
    /// browser-graded and so cannot offer it.
    let githubSubmission: GitHubSubmissionSetting?
    /// The Language select's options, in `AssignmentLanguage.allCases` order
    /// behind the "detect automatically" entry. Built from `allCases` rather
    /// than written out in the template so a sixth language needs no Leaf edit —
    /// the same discovered-not-enumerated rule the kernel-alias generator and
    /// the runner's capability probe follow.
    let assignmentLanguageOptions: [SelectOption]
    /// "C++ or Racket" — the languages whose assignments are upload-only,
    /// derived so the fine print cannot name fewer of them than the rule
    /// enforces. The create page carries the same fine print.
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
    /// The assignment gate for AI-assisted feedback
    /// (docs/ai-assisted-feedback.md). Nil while the course gate is off, so
    /// the "Student Options" control does not render at all.
    var aiFeedback: AIFeedbackSetting?
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

/// The edit page's Language select. Each value is an `AssignmentLanguage`
/// raw value, or "" for the no-language entry.
enum AssignmentLanguageOption {
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
    static func options(recorded: String?) -> [SelectOption] {
        let normalized = recorded?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noLanguage = SelectOption(
            value: noLanguageChoice,
            label: "None — plain shell scripts",
            selected: normalized == nil || AssignmentLanguage(rawValue: normalized ?? "") == nil
        )
        return [noLanguage]
            + AssignmentLanguage.allCases.map { language in
                SelectOption(
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
    let kindOptions: [SelectOption]
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
    let opponentFileOptions: [SelectOption]
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

/// The Activity section's "Opponent file" select. Each value is a support
/// filename, or "" for none.
enum OpponentFileOption {
    /// The empty choice followed by every support file. A stored file the
    /// setup no longer contains (deleted after it was chosen) is listed too,
    /// marked selected, so the page shows what the worker will fail on rather
    /// than silently showing "None chosen".
    static func options(supportFiles: [String], current: String?) -> [SelectOption] {
        var names = supportFiles
        if let current, !names.contains(current) { names.append(current) }
        return [SelectOption(value: "", label: "None chosen", selected: current == nil)]
            + names.map { SelectOption(value: $0, label: $0, selected: $0 == current) }
    }
}

/// The edit page's "Class activity" select. Each value is an `ActivityKind`
/// raw value, or `SetActivityTool.noActivityChoice`.
enum ActivityKindOption {
    /// "None" followed by every kind, marking the stored one selected.
    static func options(current: ActivityKind?) -> [SelectOption] {
        [SelectOption(value: SetActivityTool.noActivityChoice, label: "None", selected: current == nil)]
            + ActivityKind.allCases.map { kind in
                SelectOption(value: kind.rawValue, label: kind.displayName, selected: kind == current)
            }
    }
}

/// The GitHub submission checkbox's state.
/// The assignment's AI-assisted feedback gate, shown only in a course whose
/// admin gate is on.
struct AIFeedbackSetting: Encodable {
    let enabled: Bool
}

struct GitHubSubmissionSetting: Encodable {
    let enabled: Bool
    /// Commit statuses (slice 6).
    let statusChecks: Bool
}
