// APIServer/Views/AssignmentEditBody.swift
//
// The assignment editor: the name and dates form, the Files table, the
// Activity and Student Options forms, Global Inputs, the Test Suite, the
// Achievements editor, the JSON seeds the editor scripts read, and those
// scripts. `AssignmentEditPage` renders it standalone. It takes plain values
// and no request, so the workbench's left pane can render it too.
//
// `data-ck-inplace` marks every form here whose handler answers with a
// redirect to the standalone editor. That is right standalone and wrong inside
// a workbench pane, where the redirect lands in the pane. When
// inplace-forms.js is loaded (embedded renders only) it fetches the POST and
// re-renders the pane instead. The attribute is unconditional: the script is
// not loaded on the standalone page, so it is inert there.
//
// Several forms live outside the multipart Save & Validate form on purpose:
// a browser strips a nested form, and each of them persists through its own
// endpoint, so it neither closes nor re-validates the assignment.
//
// Keep in step with `_assignment-edit-body.leaf` while both exist.

import Elementary

struct AssignmentEditBody: HTML {
    let edit: EditAssignmentContext
    let csrfToken: String
    let appVersion: String

    private func asset(_ path: String) -> String {
        "\(path)?v=\(appVersion)"
    }

    var body: some HTML {
        if let error = edit.error {
            div(.class("error-box")) {
                h2 { "Could not update assignment" }
                p(.class("card-meta error-detail")) { error }
            }
        }
        form(
            .class("form form--wide"), .method(.post), .action("/instructor/\(edit.assignmentID)/edit/save"),
            .enctype(.multipartFormData), .novalidate, .dataFlag("ck-inplace")
        ) {
            CSRFField(token: csrfToken)
            EditTitlebar(edit: edit)
            EditFilesBlock(edit: edit, csrfToken: csrfToken)
        }
        if edit.activity.isSet {
            EditActivityBlock(assignmentID: edit.assignmentID, activity: edit.activity, csrfToken: csrfToken)
        }
        EditStudentOptionsBlock(edit: edit, csrfToken: csrfToken)
        EditGlobalInputsBlock(assignmentID: edit.assignmentID, rows: edit.globalVariableRows)
        label(.class("visually-hidden"), .for("suite-files-input")) { "Add test suite files" }
        " "
        input(.class("form-input"), .id("suite-files-input"), .type(.file), .multiple, .hidden)
        EditSuiteBlock(edit: edit, csrfToken: csrfToken)
        EditAchievementsBlock(edit: edit)
        // The editor scripts parse these once at page load.
        JSONIsland(id: "suite-state-seed", json: edit.suiteStateJSON)
        JSONIsland(id: "pattern-families-seed", json: edit.patternFamiliesJSON)
        JSONIsland(id: "notebook-checks-seed", json: edit.notebookChecksJSON)
        JSONIsland(id: "check-schema", json: edit.checkSchemaJSON)
        JSONIsland(id: "assignment-language-seed", json: edit.assignmentLanguageJSON)
        script(.src(asset("/authoring-language.js"))) {}
        // A body renderer of the unified Test Editor modal: the modal shell
        // owns the chrome, and the renderer moves this hidden body into it.
        FamilyEditorBody()
        // The shared editor modules load first. Public/assignment-edit-page.js
        // loads last and wires them to this assignment's endpoints. Renderer
        // scripts load before the modal shell so they register first.
        script(.src(asset("/suite-table.js"))) {}
        script(.src(asset("/inputs-editor-core.js"))) {}
        script(.src(asset("/section-inputs-editor.js"))) {}
        script(.src(asset("/auto-compute-client.js"))) {}
        script(.src(asset("/pattern-family-editor.js"))) {}
        script(.src(asset("/global-inputs-editor.js"))) {}
        script(.src(asset("/achievements-editor-core.js"))) {}
        script(.src(asset("/achievements-editor.js"))) {}
        script(.src(asset("/test-renderer-check-core.js"))) {}
        script(.src(asset("/test-renderer-check.js"))) {}
        script(.src(asset("/test-renderer-script-core.js"))) {}
        script(.type(.module), .src(asset("/test-renderer-script.js"))) {}
        script(.src(asset("/test-editor-modal.js"))) {}
        script(.src(asset("/support-files.js"))) {}
        script(.src(asset("/assignment-edit-page.js"))) {}
        PageStyle(
            """
            .bs-assess-row { display: flex; gap: .4rem; align-items: center; }
            .bs-assess-row input[type="text"] { flex: 1; }
            .suite-default-limit-label { display: inline-flex; align-items: center; gap: .3rem; font-size: var(--text-sm); color: var(--gray-500); }
            .suite-default-limit-input { width: 4.5rem; }
            """
        )
    }
}

/// The title row: the name in view mode, the inline edit block behind the
/// pencil, and the page actions.
private struct EditTitlebar: HTML {
    let edit: EditAssignmentContext

    var body: some HTML {
        div(.class("editor-titlebar")) {
            div(.class("editor-title-col")) {
                div(.id("assign-header-view"), .class("assign-header-view")) {
                    h1 { edit.assignmentName }
                    span(.class("card-meta fine-print"), .id("assign-due-display")) {}
                    " "
                    button(
                        .class("btn-link icon-btn-text"), .id("assign-edit-toggle"), .type(.button),
                        .title("Edit name and due date"), .ariaLabel("Edit assignment name and due date")
                    ) {
                        " "
                        Icon("i-pencil")
                        " "
                    }
                }
                EditHeaderFields(edit: edit)
            }
            div(.class("editor-actions")) {
                if edit.embedded == true {
                    // The workbench's one Save submits this form. `liveEdit`
                    // makes that Save leave the assignment's visibility alone.
                    input(.type(.hidden), .name("liveEdit"), .value("1"))
                } else {
                    span(.class("field-note field-note--muted"), .id("suite-live-save-note")) {
                        "Suite edits save as you make them."
                    }
                    " "
                    button(
                        .class("btn btn-primary"), .type(.submit),
                        .custom(name: "aria-describedby", value: "suite-live-save-note"),
                        .title("Save the name, due date and notebooks, then re-validate")
                    ) {
                        "Save & Validate"
                    }
                    // Absent in the workbench pane: the pane must not link to
                    // the surface that contains it.
                    " "
                    a(
                        .class("btn"), .href("/instructor/\(edit.assignmentID)/workbench"),
                        .title("Edit this assignment beside the notebook editor")
                    ) { "Workbench" }
                    " "
                    a(.class("btn"), .href("/instructor")) { "Cancel" }
                }
            }
        }
    }
}

/// The inline edit block behind the pencil, hidden until it is clicked.
private struct EditHeaderFields: HTML {
    let edit: EditAssignmentContext

    var body: some HTML {
        div(.id("assign-header-edit"), .class("assign-header-edit"), .custom(name: "style", value: "display:none")) {
            div(.class("assign-header-edit-top")) {
                strong(.class("subhead-label")) { "Name & Due Date" }
                " "
                button(
                    .class("btn-link icon-btn-text"), .id("assign-edit-cancel"), .type(.button), .ariaLabel("Cancel"),
                    .title("Cancel")
                ) { "✕" }
            }
            label(.class("form-label field-gap")) {
                "Assignment Name "
                input(
                    .class("form-input"), .type(.text), .name("assignmentName"), .id("assignmentNameInput"), .required,
                    .value(edit.assignmentName), .placeholder("e.g. Lab 2 - Linked Lists"))
                " "
            }
            " "
            if edit.brightspaceSyncEnabled {
                div(.class("form-label field-gap")) {
                    "LEARN Assessment "
                    div(.class("bs-assess-row")) {
                        datalist(.id("edit-bs-grade-objects")) {}
                        input(.type(.hidden), .name("gradeObjectID"), .id("edit-bs-grade-id"))
                        " "
                        input(
                            .class("form-input"), .type(.text), .id("edit-bs-grade-name"),
                            .list("edit-bs-grade-objects"), .data("raw-id", value: edit.brightspaceGradeObjectID ?? ""),
                            .placeholder("Search assessments…"), .autocomplete(.off))
                    }
                }
            }
            label(.class("form-label field-gap")) {
                "Open Date (optional) "
                input(
                    .class("form-input"), .type(.datetimeLocal), .name("startsAt"), .id("startsAt"),
                    .value(edit.startsAt))
                " "
            }
            " "
            label(.class("form-label")) {
                "Due Date (optional) "
                input(.class("form-input"), .type(.datetimeLocal), .name("dueAt"), .id("dueAt"), .value(edit.dueAt))
                " "
            }
            " "
            label(.class("form-label field-gap")) {
                "Language "
                select(.class("form-input"), .name("assignmentLanguage"), .id("assignmentLanguageSelect")) {
                    SelectOptions(options: edit.assignmentLanguageOptions)
                }
                " "
            }
            p(.class("card-meta fine-print")) {
                "Chickadee normally works the language out from the starter notebook's kernel or a test script's "
                    + "extension. Declare it when there is nothing to work it out from — a suite made only of "
                    + "pattern families — or for C++, whose generated tests are shell wrappers carrying no language "
                    + "extension. \(edit.uploadOnlyLanguagesProse) assignments are upload-only and have no notebook "
                    + "editor. Declare the language before adding pattern families or notebook checks: their "
                    + "filenames carry the language's extension, so it cannot be changed once they exist."
            }
            label(.class("form-label field-gap")) {
                "Submission Method "
                select(.class("form-input"), .name("submissionMode"), .id("submissionModeSelect")) {
                    option(.value("notebook")) { "Notebook editor" }
                        .attributes(.selected, when: edit.submissionMode == "notebook")
                    option(.value("uploadOnly")) { "File upload only" }
                        .attributes(.selected, when: edit.submissionMode == "uploadOnly")
                }
                " "
            }
            p(.class("card-meta fine-print")) {
                "File upload only hides the notebook editor and grades every submission on the native runner. "
                    + "Use it for makefile-graded work (for example C++) or multi-file projects submitted as a zip."
            }
            label(.class("form-label field-gap")) {
                "Class activity "
                select(.class("form-input"), .name("activityKind"), .id("activityKindSelect")) {
                    SelectOptions(options: edit.activity.kindOptions)
                }
                .attributes(.disabled, when: edit.activity.locked)
                " "
            }
            p(.class("card-meta fine-print")) {
                if edit.activity.locked {
                    "The activity kind is locked because students have submitted. "
                        + "Clone the assignment to run it as a different kind."
                } else {
                    "A class activity ranks students on the number a test script reports as "
                    code { "metric" }
                    " in its JSON footer, highest first. See the class activities guide in docs before choosing one."
                }
            }
            div(.id("uw-date-warning"), .class("card-meta date-warning"), .custom(name: "style", value: "display:none"))
            {}
        }
    }
}

/// The Files table: the two notebooks and the support files.
private struct EditFilesBlock: HTML {
    let edit: EditAssignmentContext
    let csrfToken: String

    var body: some HTML {
        div(.class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Files" }
                div(.class("toolbar toolbar--end")) {
                    button(
                        .class("btn action-btn"), .type(.button), .id("add-support-file-btn"),
                        .title("Upload a data file (CSV, JSON, etc.) bundled with the assignment")
                    ) { "+ Add Support File" }
                    " "
                    input(.type(.file), .id("support-file-upload-input"), .hidden, .multiple)
                    " "
                    span(
                        .id("support-file-upload-status"), .class("upload-status-inline"), .role("status"),
                        .custom(name: "aria-live", value: "polite")
                    ) {}
                }
            }
            table(.class("results-table"), .id("notebook-files-table")) {
                thead {
                    tr {
                        th { "Name" }
                        th { "File" }
                        th(.class("time")) { "Action" }
                    }
                }
                tbody {
                    tr {
                        td { strong { "Assignment Notebook" } }
                        td {
                            a(.href(edit.currentAssignmentURL)) {
                                code(.id("assignment-notebook-name")) { edit.currentAssignmentFile }
                            }
                        }
                        td(.class("time")) {
                            a(
                                .class("btn action-btn"), .id("assignment-notebook-edit-btn"),
                                .data("wb-file", value: "assignment"), .href(edit.assignmentNotebookEditURL)
                            ) { "Edit" }
                        }
                    }
                    solutionRow
                    for file in edit.supportFileRows {
                        SupportFileRow(file: file)
                    }
                }
            }
        }
    }

    private var solutionRow: some HTML {
        tr {
            td { strong { "Solution Notebook" } }
            td {
                if let url = edit.currentSolutionURL {
                    a(.href(url)) { code(.id("solution-notebook-name")) { edit.currentSolutionFile ?? "" } }
                } else {
                    code(.id("solution-notebook-name")) { "not set" }
                }
            }
            td(.class("time")) {
                if let editURL = edit.solutionNotebookEditURL {
                    a(
                        .class("btn action-btn"), .id("solution-notebook-edit-btn"),
                        .data("wb-file", value: "solution"), .href(editURL)
                    ) { "Edit" }
                } else {
                    form(
                        .method(.post), .action("/instructor/\(edit.assignmentID)/create-solution"),
                        .class("inline-form"), .dataFlag("ck-inplace")
                    ) {
                        CSRFField(token: csrfToken)
                        " "
                        button(
                            .class("btn action-btn"), .type(.submit),
                            .title("Copy the assignment notebook as a starting point for the solution")
                        ) { "Create solution" }
                    }
                }
            }
        }
    }
}

/// The Activity section, shown only when the manifest carries an activity
/// block. Publishing a leaderboard mid-lab never closes or re-validates the
/// assignment.
private struct EditActivityBlock: HTML {
    let assignmentID: String
    let activity: ActivityEditFacts
    let csrfToken: String

    var body: some HTML {
        section(.class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Activity" }
                div(.class("toolbar toolbar--end")) {
                    span(.class("chip")) { activity.kindLabel }
                    " "
                    a(.class("btn action-btn"), .href(activity.leaderboardURL)) { "Open leaderboard" }
                }
            }
            p(.class("field-note field-note--muted")) { activity.summary }
            form(.method(.post), .action("/instructor/\(assignmentID)/activity"), .dataFlag("ck-inplace")) {
                CSRFField(token: csrfToken)
                " "
                label(.class("form-label")) {
                    " "
                    input(.type(.checkbox), .name("visible"))
                        .attributes(.checked, when: activity.leaderboardVisible)
                    " Show the leaderboard to students"
                }
                p(.class("field-note field-note--muted")) {
                    "Students see each entry by class handle, with rank and metric only."
                }
                button(.class("btn action-btn"), .type(.submit)) { "Save leaderboard setting" }
            }
            if activity.needsOpponentFile {
                opponentForm
            }
            form(.method(.post), .action("/instructor/\(assignmentID)/activity/window"), .dataFlag("ck-inplace")) {
                CSRFField(token: csrfToken)
                " "
                label(.class("form-label")) {
                    "Session opens (optional) "
                    input(
                        .class("form-input"), .type(.datetimeLocal), .name("opensAt"),
                        .value(activity.windowOpensAtLocal))
                    " "
                }
                " "
                label(.class("form-label")) {
                    "Session closes (optional) "
                    input(
                        .class("form-input"), .type(.datetimeLocal), .name("closesAt"),
                        .value(activity.windowClosesAtLocal))
                    " "
                }
                p(.class("field-note field-note--muted")) { "Submissions outside these times are refused." }
                button(.class("btn action-btn"), .type(.submit)) { "Save session window" }
            }
        }
    }

    private var opponentForm: some HTML {
        form(.method(.post), .action("/instructor/\(assignmentID)/activity/opponent"), .dataFlag("ck-inplace")) {
            CSRFField(token: csrfToken)
            " "
            label(.class("form-label")) {
                "Opponent file "
                select(.class("form-input"), .name("opponentFile")) {
                    SelectOptions(options: activity.opponentFileOptions)
                }
                " "
            }
            p(.class("field-note field-note--muted")) {
                if activity.opponentFileChosen {
                    "The worker copies this file into the directory "
                    code { "CHICKADEE_OPPONENT_DIR" }
                    " names, where the match script reads it."
                } else {
                    "Nothing is staged for the match script until you upload the bot as a support file and select it here."
                }
            }
            button(.class("btn action-btn"), .type(.submit)) { "Save opponent file" }
        }
    }
}

/// Per-assignment student-facing policy toggles. A mid-semester flip neither
/// closes nor re-validates the assignment.
private struct EditStudentOptionsBlock: HTML {
    let edit: EditAssignmentContext
    let csrfToken: String

    private var base: String { "/instructor/\(edit.assignmentID)" }

    var body: some HTML {
        section(.class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Student Options" }
            }
            form(.method(.post), .action("\(base)/secret-reveal"), .dataFlag("ck-inplace")) {
                CSRFField(token: csrfToken)
                " "
                label(.class("form-label")) {
                    " "
                    input(.type(.checkbox), .name("enabled"))
                        .attributes(.checked, when: edit.secretRevealEnabled)
                    " Allow each student to spend their one reveal token to see this assignment’s secret test results"
                }
                p(.class("field-note field-note--muted")) {
                    "The reveal does not change grades, and a spent token stays spent until staff give it back."
                }
                button(.class("btn action-btn"), .type(.submit)) { "Save reveal setting" }
            }
            if let aiFeedback = edit.aiFeedback {
                form(.method(.post), .action("\(base)/ai-feedback"), .dataFlag("ck-inplace")) {
                    CSRFField(token: csrfToken)
                    " "
                    label(.class("form-label")) {
                        " "
                        input(.type(.checkbox), .name("enabled"))
                            .attributes(.checked, when: aiFeedback.enabled)
                        " Allow course staff to draft feedback on written answers with an AI agent"
                    }
                    p(.class("field-note field-note--muted")) {
                        "The agent reads cells tagged "
                        code { "reflection" }
                        ", without names, and staff review every draft on the "
                        a(.href("\(base)/feedback")) { "feedback page" }
                        " before students see it."
                    }
                    button(.class("btn action-btn"), .type(.submit)) { "Save feedback setting" }
                }
            }
            form(.method(.post), .action("\(base)/solution-visibility"), .dataFlag("ck-inplace")) {
                CSRFField(token: csrfToken)
                " "
                label(.class("form-label")) {
                    " "
                    input(.type(.checkbox), .name("afterDue"))
                        .attributes(.checked, when: edit.solutionVisibilityAfterDue)
                    " Show the reference solution to each student once their deadline has passed"
                }
                p(.class("field-note field-note--muted")) {
                    "Each student’s reveal waits for their own deadline, including extensions and any slip days "
                        + "they could still claim."
                }
                button(.class("btn action-btn"), .type(.submit)) { "Save solution setting" }
            }
            if let github = edit.githubSubmission {
                githubForm(github)
            }
            form(.method(.post), .action("\(base)/passing-threshold"), .dataFlag("ck-inplace")) {
                CSRFField(token: csrfToken)
                " "
                label(.class("field-inline")) {
                    "Passing threshold (%) "
                    input(
                        .type(.number), .name("passingThresholdPercent"), .min(1), .max(100), .step(1),
                        .class("form-input input-compact"), .value(edit.passingThresholdPercent.map(String.init) ?? ""),
                        .placeholder("off"))
                    " "
                }
                p(.class("field-note field-note--muted")) {
                    "Students whose best grade reaches this appear as passing on the submissions page; "
                        + "grades are unaffected."
                }
                button(.class("btn action-btn"), .type(.submit)) { "Save passing threshold" }
            }
        }
    }

    private func githubForm(_ github: GitHubSubmissionSetting) -> some HTML {
        form(.method(.post), .action("\(base)/github-submission"), .dataFlag("ck-inplace")) {
            CSRFField(token: csrfToken)
            " "
            label(.class("form-label")) {
                " "
                input(.type(.checkbox), .name("enabled"))
                    .attributes(.checked, when: github.enabled)
                " Allow submission from a GitHub commit"
            }
            p(.class("field-note field-note--muted")) {
                "Students can also submit a commit from a GitHub repository they own, or from a "
                a(.href("/instructor/github")) { "course repository" }
                "."
            }
            label(.class("form-label")) {
                " "
                input(.type(.checkbox), .name("statusChecks"))
                    .attributes(.checked, when: github.statusChecks)
                " Post commit status"
            }
            p(.class("field-note field-note--muted")) {
                "Posts only the public-test count to a private repository, and needs GitHub submission on and a "
                    + "GitHub App with commit statuses."
            }
            button(.class("btn action-btn"), .type(.submit)) { "Save GitHub setting" }
        }
    }
}

/// Assignment-scope named values (#461), saved through their own PUT
/// endpoint (`/instructor/:id/global-variables`) by global-inputs-editor.js.
private struct EditGlobalInputsBlock: HTML {
    let assignmentID: String
    let rows: [SuiteSectionVariableShellRow]

    var body: some HTML {
        section(.id("global-inputs-block"), .data("assignment-id", value: assignmentID), .class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Global Inputs" }
                div(.class("toolbar toolbar--end")) {
                    button(.type(.button), .class("btn action-btn"), .id("global-input-add")) { "+ Add Input" }
                    " "
                    span(
                        .id("global-inputs-status"), .class("upload-status-inline"), .role("status"),
                        .custom(name: "aria-live", value: "polite")
                    ) {}
                }
            }
            table(.class("results-table"), .id("global-inputs-table")) {
                tbody(.class("js-global-inputs-body")) {
                    for row in rows {
                        GlobalInputRow(row: row)
                    }
                }
            }
            ValueCueNote()
        }
    }
}

private struct GlobalInputRow: HTML {
    let row: SuiteSectionVariableShellRow

    var body: some HTML {
        tr(.class("js-global-input-row")) {
            td(.class("section-var-namecell")) {
                span(.class("js-global-input-row-valid section-var-valid")) {}
                " "
                input(
                    .type(.text),
                    .class("form-input cell-input cell-input--with-check input-mono js-global-input-name"),
                    .value(row.name), .placeholder("Input Name"))
            }
            td {
                input(
                    .type(.text), .class("form-input cell-input input-mono js-global-input-value"), .ariaLabel("Value"),
                    .value(row.valueJSON), .placeholder(#"12, "hello", [1, 2, 3], or = seed % 26"#))
            }
            td(.class("time")) {
                button(
                    .type(.button), .class("btn action-btn action-danger js-global-input-remove"),
                    .title("Remove input"), .ariaLabel("Remove input")
                ) {
                    " "
                    Icon("i-trash")
                    " "
                }
            }
        }
    }
}

/// The Test Suite. Item edits go through `PUT /suite` from suite-table.js and
/// section CRUD through `POST /suite-sections/*`; none of them use the Save
/// form, which is why the block lives outside it.
private struct EditSuiteBlock: HTML {
    let edit: EditAssignmentContext
    let csrfToken: String

    var body: some HTML {
        div(.class("suite-editor-section")) {
            div(.class("editor-block-head")) {
                h2 { "Test Suite" }
                div(.class("toolbar toolbar--end")) {
                    // The assignment-wide default per-test time limit (#979),
                    // saved live through PUT /instructor/:id/time-limit.
                    label(.class("suite-default-limit-label"), .for("suite-default-time-limit")) {
                        "Default time limit "
                        input(
                            .class("form-input input-compact suite-default-limit-input"), .type(.number), .min(1),
                            .max(600), .step(1), .id("suite-default-time-limit"), .value(String(edit.timeLimitSeconds)),
                            .title("Seconds before a test times out, unless the test sets its own limit."))
                        " s "
                        span(
                            .id("suite-default-limit-status"), .class("upload-status-inline"), .role("status"),
                            .custom(name: "aria-live", value: "polite")
                        ) {}
                        " "
                    }
                    details(.class("add-section-details popup-anchor"), .id("add-suite-section-details")) {
                        summary(.class("btn action-btn summary-btn")) { "+ Section" }
                        div(.class("add-section-popup card suite-section-popup")) {
                            form(
                                .method(.post), .action("/instructor/\(edit.assignmentID)/suite-sections"),
                                .class("form popup-form"), .dataFlag("ck-inplace")
                            ) {
                                CSRFField(token: csrfToken)
                                " "
                                label(.class("form-label")) {
                                    "Section name "
                                    input(
                                        .class("form-input editor-input"), .type(.text), .name("name"),
                                        .placeholder("e.g. Question 1"), .required)
                                    " "
                                }
                                " "
                                button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Create section" }
                            }
                        }
                    }
                    // The file-input trigger suite-table.js wires; tests are
                    // added per section now.
                    button(.class("btn action-btn"), .type(.button), .id("add-test-btn"), .hidden) { "Upload" }
                }
            }
            p(.class("field-note field-note--muted")) {
                "Drag a test onto another test in the same section to make it depend on that test."
            }
            SuiteSections(
                rows: edit.suiteSectionRows, actionBase: edit.sectionActionBase, actionQuery: edit.sectionActionQuery,
                formsInPlace: edit.sectionFormsInPlace, csrfToken: csrfToken)
        }
    }
}

/// The Achievements table, persisted through PUT /instructor/:id/achievements.
/// achievements-editor.js clones the two templates into an accordion row
/// beneath the achievement being edited, and every Save or Remove persists at
/// once.
private struct EditAchievementsBlock: HTML {
    let edit: EditAssignmentContext

    var body: some HTML {
        section(.id("achievements-block"), .data("assignment-id", value: edit.assignmentID), .class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Achievements" }
                div(.class("toolbar toolbar--end")) {
                    button(.type(.button), .class("btn action-btn"), .id("achievement-add")) { "+ Add Achievement" }
                    " "
                    span(
                        .id("achievements-status"), .class("upload-status-inline"), .role("status"),
                        .custom(name: "aria-live", value: "polite")
                    ) {}
                }
            }
            table(.class("results-table"), .id("achievements-table")) {
                thead {
                    tr {
                        th { "Name" }
                        th { "Scope" }
                        th { "Earned when" }
                        th {}
                    }
                }
                tbody(.class("achievements-body")) {}
            }
            template(.id("achievement-editor-template")) {
                AchievementEditorFields(recordDimensionOptions: edit.recordDimensionOptions)
            }
            // One condition row, cloned into #am-conditions per condition.
            template(.id("achievement-condition-template")) {
                AchievementConditionRow(signalOptions: edit.achievementSignalOptions)
            }
        }
    }
}

/// The inline achievement editor. Fields show and hide by scope.
private struct AchievementEditorFields: HTML {
    let recordDimensionOptions: [RecordDimensionOption]

    var body: some HTML {
        label(.class("form-label field-gap")) {
            "Name "
            input(.type(.text), .class("form-input"), .id("am-name"), .placeholder("e.g. 80% Mastery"))
            " "
        }
        " "
        label(.class("form-label field-gap")) {
            "Description (optional) "
            input(
                .type(.text), .class("form-input"), .id("am-detail"),
                .placeholder("Shown to students - how to earn this."))
            " "
        }
        " "
        label(.class("form-label field-gap")) {
            "Awarded to "
            select(.class("form-input"), .id("am-scope")) {
                option(.value("individual")) { "This student" }
                option(.value("classWide")) { "The class together" }
                option(.value("record")) { "Class record (one holder)" }
            }
            " "
        }
        // The signal options come from AchievementSignalPresentation; the
        // editor clones the condition row per condition.
        div(.class("js-am-scope-field"), .data("scope", value: "individual classWide")) {
            div(.class("subhead-label")) {
                "Earned when "
                select(.class("form-input form-input--inline"), .id("am-match")) {
                    option(.value("all")) { "all" }
                    option(.value("any")) { "any" }
                }
                " of these conditions hold:"
            }
            div(.id("am-conditions"), .class("am-conditions")) {}
            button(.type(.button), .class("btn action-btn"), .id("am-add-condition")) { "+ Add condition" }
        }
        label(.class("form-label field-gap js-am-scope-field"), .data("scope", value: "classWide")) {
            "Class share ≥ (%) "
            input(.type(.number), .class("form-input"), .id("am-classPercent"), .min(0), .max(100))
            " "
        }
        " "
        label(.class("form-label field-gap js-am-scope-field"), .data("scope", value: "classWide")) {
            "Bonus points "
            input(.type(.number), .class("form-input"), .id("am-points"), .min(0))
            " "
        }
        " "
        label(.class("form-label field-gap js-am-scope-field"), .data("scope", value: "record")) {
            "Ranked by "
            select(.class("form-input"), .id("am-recordDimension")) {
                for dimension in recordDimensionOptions {
                    option(.value(dimension.value)) { dimension.label }
                }
            }
            " "
        }
    }
}

private struct AchievementConditionRow: HTML {
    let signalOptions: [AchievementSignalOption]

    var body: some HTML {
        div(.class("am-condition")) {
            select(.class("form-input am-cond-signal"), .ariaLabel("Measure")) {
                for signal in signalOptions {
                    option(
                        .value(signal.value), .data("unit", value: signal.unit), .data("scope", value: signal.scopes),
                        .data("ref-control", value: signal.refControl), .data("ref-field", value: signal.refField),
                        .data("ref-label", value: signal.refLabel),
                        .data("ref-placeholder", value: signal.refPlaceholder),
                        .data("ref-replaces-value", value: signal.refReplacesValue ? "true" : "false")
                    ) { signal.label }
                }
            }
            " "
            select(.class("form-input js-am-cond-comparator"), .ariaLabel("Comparison")) {
                option(.value("atLeast")) { "at least" }
                option(.value("atMost")) { "at most" }
                option(.value("equals")) { "exactly" }
            }
            " "
            input(.type(.number), .class("form-input am-cond-value"), .ariaLabel("Value"))
            " "
            span(.class("am-cond-unit")) {}
            " "
            input(.type(.text), .class("form-input am-cond-ref"), .custom(name: "style", value: "display:none"))
            " "
            // Filled by the editor from the live suite sections on the page,
            // so a section added or renamed without a reload shows under its
            // current name.
            select(.class("form-input am-cond-ref"), .custom(name: "style", value: "display:none")) {}
            " "
            button(
                .type(.button), .class("btn action-btn action-danger am-cond-remove"), .ariaLabel("Remove condition")
            ) {
                "×"
            }
        }
    }
}
