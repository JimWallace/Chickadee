// APIServer/Views/Pages/AssignmentNewPage.swift
//
// GET /instructor/new: the Create Assignment page. Before the first notebook
// upload there is no draft setup and no suite to author. Once a draft exists
// the page carries the suite editor, wired to the draft-scoped endpoints
// (`PUT /instructor/new/draft/suite`, `POST /instructor/new/draft/suite-sections/*`).
// It shares the suite sections, the family editor body, the support-file rows
// and the editor scripts with the edit page; Public/assignment-new-page.js
// wires them here.

import Elementary

struct AssignmentNewPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let error: String?
    let assignmentName: String
    let startsAt: String
    let dueAt: String
    /// The course sections the picker offers.
    let sections: [CourseSectionRow]
    /// From `?sectionID=`, or the stored draft state.
    let preselectedSectionID: String
    /// Nil before the first notebook upload creates the draft setup.
    let draftID: String?
    /// `draftID` as JSON: a quoted string, or `null`.
    let draftIDJSON: String
    let assignmentLanguageOptions: [SelectOption]
    let assignmentNotebook: NewAssignmentNotebookContext?
    let solutionNotebook: NewAssignmentNotebookContext?
    let supportFileRows: [EditableSuiteRow]
    let detectedLanguages: [String]
    let detectedCapabilities: [String]
    let requiredLanguagesCSV: String
    let requiredCapabilitiesCSV: String
    let suiteSectionRows: [SuiteSectionShellRow]
    /// The full reconciled `GET /suite` payload; `{"items":[]}` with no draft.
    let suiteStateJSON: String
    let patternFamiliesJSON: String
    let notebookChecksJSON: String
    let checkSchemaJSON: String
    let assignmentLanguageJSON: String

    var body: some HTML {
        BaseLayout(title: "Create Assignment", page: page, flash: flash) {
            if let error {
                div(.class("error-box")) {
                    h2 { "Could not create assignment" }
                    p(.class("card-meta error-detail")) { error }
                }
            }
            form(
                .class("form form--wide"), .method(.post), .action("/instructor/new/save"),
                .enctype(.multipartFormData), .id("new-assignment-form"), .novalidate
            ) {
                CSRFField(token: page.csrfToken)
                if let draftID {
                    " "
                    input(.type(.hidden), .name("draftID"), .value(draftID))
                }
                NewAssignmentTitlebar(
                    assignmentName: assignmentName, startsAt: startsAt, dueAt: dueAt, sections: sections,
                    preselectedSectionID: preselectedSectionID, assignmentLanguageOptions: assignmentLanguageOptions)
                draftActionButtons
                NewAssignmentFilesBlock(
                    hasDraft: draftID != nil, assignmentNotebook: assignmentNotebook,
                    solutionNotebook: solutionNotebook, supportFileRows: supportFileRows)
                runnerRequirements
            }
            if let draftID {
                label(.class("visually-hidden"), .for("suite-files-input")) { "Add test suite files" }
                " "
                input(.class("form-input"), .id("suite-files-input"), .type(.file), .multiple, .hidden)
                NewAssignmentSuiteBlock(draftID: draftID, rows: suiteSectionRows, csrfToken: page.csrfToken)
                JSONIsland(id: "suite-state-seed", json: suiteStateJSON)
            } else {
                // No draft yet: the notebook upload above creates it, and the
                // page reloads with the suite editor.
                div(.class("predraft-note")) {
                    strong { "Test Suite" }
                    " — upload an assignment notebook above to begin authoring tests."
                }
            }
            JSONIsland(id: "pattern-families-seed", json: patternFamiliesJSON)
            JSONIsland(id: "notebook-checks-seed", json: notebookChecksJSON)
            JSONIsland(id: "check-schema", json: checkSchemaJSON)
            JSONIsland(id: "assignment-language-seed", json: assignmentLanguageJSON)
            // Page facts for Public/assignment-new-page.js.
            JSONIsland(id: "new-assignment-config", json: configJSON)
            script(.src(page.asset("/authoring-language.js"))) {}
            FamilyEditorBody()
            script(.src(page.asset("/auto-compute-client.js"))) {}
            script(.src(page.asset("/pattern-family-editor.js"))) {}
            if draftID != nil {
                script(.src(page.asset("/suite-table.js"))) {}
                script(.src(page.asset("/inputs-editor-core.js"))) {}
                script(.src(page.asset("/section-inputs-editor.js"))) {}
            }
            // The Generate Starter Tests panel's init runs with or without a
            // draft; with none it reports that one is needed.
            script(.src(page.asset("/generated-starter-tests-core.js"))) {}
            script(.src(page.asset("/generated-starter-tests.js"))) {}
            // Renderer scripts load before the modal shell so they register
            // first.
            script(.src(page.asset("/test-renderer-check-core.js"))) {}
            script(.src(page.asset("/test-renderer-check.js"))) {}
            script(.src(page.asset("/test-renderer-script-core.js"))) {}
            script(.type(.module), .src(page.asset("/test-renderer-script.js"))) {}
            script(.src(page.asset("/test-editor-modal.js"))) {}
            script(.src(page.asset("/support-files.js"))) {}
            script(.src(page.asset("/assignment-new-page.js"))) {}
        }
    }

    /// `{"draftID":...,"hasSolutionNotebook":...}`, in that key order.
    private var configJSON: String {
        "{\"draftID\":\(draftIDJSON),\"hasSolutionNotebook\":\(solutionNotebook != nil ? "true" : "false")}"
    }

    /// The hidden notebook file inputs and the hidden submit buttons for the
    /// draft notebook actions. The page script fires them.
    @HTMLBuilder private var draftActionButtons: some HTML {
        input(
            .type(.file), .id("assignment-notebook-file-input"), .name("assignmentNotebookFile"), .accept(".ipynb"),
            .hidden)
        " "
        input(
            .type(.file), .id("solution-notebook-file-input"), .name("solutionNotebookFile"), .accept(".ipynb"),
            .hidden)
        for action in Self.draftActions {
            " "
            button(
                .id("js-\(action)"), .type(.submit), .custom(name: "formaction", value: "/instructor/new/draft"),
                .name("draftAction"), .custom(name: "value", value: action), .hidden
            ) {}
        }
    }

    private static let draftActions = [
        "upload-assignment-notebook", "upload-solution-notebook", "create-assignment-notebook",
        "create-solution-notebook", "create-solution-from-assignment", "clear-assignment-notebook",
        "clear-solution-notebook",
    ]

    @HTMLBuilder private var runnerRequirements: some HTML {
        if !detectedLanguages.isEmpty {
            p(.class("card-meta detected-note")) {
                strong { "Auto-detected:" }
                " Languages: \(detectedLanguages.joined(separator: ", "))"
                if !detectedCapabilities.isEmpty {
                    " · Capabilities: \(detectedCapabilities.joined(separator: ", "))"
                }
            }
        }
        div(.class("runner-req-row")) {
            label(.class("req-field")) {
                "Languages "
                input(
                    .class("form-input input-sm"), .type(.text), .name("requiredLanguagesCSV"),
                    .value(requiredLanguagesCSV), .placeholder("e.g. \(LanguageProse.allTokensCSV)"))
                " "
            }
            " "
            label(.class("req-field")) {
                "Capabilities "
                input(
                    .class("form-input input-sm"), .type(.text), .name("requiredCapabilitiesCSV"),
                    .value(requiredCapabilitiesCSV), .placeholder("numpy, pandas, shell-bash"))
                " "
            }
        }
    }
}

/// The name, dates, section and language row, and the page actions.
private struct NewAssignmentTitlebar: HTML {
    let assignmentName: String
    let startsAt: String
    let dueAt: String
    let sections: [CourseSectionRow]
    let preselectedSectionID: String
    let assignmentLanguageOptions: [SelectOption]

    var body: some HTML {
        div(.class("page-titlebar page-titlebar--top")) {
            div(.class("editor-title-col")) {
                label(.class("visually-hidden"), .for("assignmentNameInput")) { "Assignment Name" }
                " "
                input(
                    .class("form-input assignment-name-input"), .type(.text), .name("assignmentName"),
                    .id("assignmentNameInput"), .required, .value(assignmentName), .placeholder("Assignment name"))
                div(.class("assignment-meta-row")) {
                    label(.class("field-inline")) {
                        "Opens "
                        input(
                            .class("form-input input-compact"), .type(.datetimeLocal), .name("startsAt"),
                            .id("startsAt"), .value(startsAt))
                        " "
                    }
                    " "
                    label(.class("field-inline")) {
                        "Due "
                        input(
                            .class("form-input input-compact"), .type(.datetimeLocal), .name("dueAt"), .id("dueAt"),
                            .value(dueAt))
                        " "
                    }
                    " "
                    if !sections.isEmpty {
                        sectionPicker
                        " "
                    }
                    label(.class("field-inline")) {
                        "Language "
                        select(
                            .class("form-input input-compact"), .name("assignmentLanguage"),
                            .id("assignmentLanguageSelect"), .required
                        ) {
                            SelectOptions(options: assignmentLanguageOptions)
                        }
                        " "
                    }
                }
                p(.class("card-meta fine-print")) {
                    "Every generated test renders in this language, so it is stated here rather than worked out "
                        + "later. Pick \"None\" for a suite of plain shell scripts. Choosing "
                        + "\(LanguageProse.uploadOnlyDisplayNames) makes the assignment upload-only, since those "
                        + "languages have no notebook editor."
                }
                div(
                    .id("uw-date-warning"), .class("card-meta date-warning"),
                    .custom(name: "style", value: "display:none")
                ) {}
                p(
                    .id("grading-mode-hint"), .class("card-meta grading-mode-hint"),
                    .custom(name: "style", value: "display:none")
                ) {}
            }
            div(.class("editor-actions")) {
                button(.class("btn btn-primary"), .type(.submit)) { "Create & Validate" }
                " "
                a(.class("btn"), .href("/instructor")) { "Cancel" }
            }
        }
    }

    private var sectionPicker: some HTML {
        label(.class("field-inline")) {
            "Section "
            select(.class("form-input input-compact"), .name("sectionID"), .id("sectionID")) {
                // The template's `selected` here negated a string, which Leaf
                // never reads as true, so this option is never marked. A
                // browser selects the first option anyway.
                option(.value("")) { "— Ungrouped —" }
                for section in sections {
                    option(.value(section.sectionID), .data("grading-mode", value: section.defaultGradingMode)) {
                        section.name
                    }
                    .attributes(.selected, when: preselectedSectionID == section.sectionID)
                }
            }
            " "
        }
    }
}

/// The Files table: the two notebooks with their draft actions, and the
/// support files.
private struct NewAssignmentFilesBlock: HTML {
    let hasDraft: Bool
    let assignmentNotebook: NewAssignmentNotebookContext?
    let solutionNotebook: NewAssignmentNotebookContext?
    let supportFileRows: [EditableSuiteRow]

    var body: some HTML {
        div(.class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Files" }
                if hasDraft {
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
                    assignmentRow
                    solutionRow
                    for file in supportFileRows {
                        SupportFileRow(file: file)
                    }
                }
            }
        }
    }

    private var assignmentRow: some HTML {
        tr {
            td { strong { "Assignment Notebook" } }
            td { NotebookLink(notebook: assignmentNotebook, codeID: "assignment-notebook-name") }
            td(.class("time")) {
                div(.class("cell-actions")) {
                    if let assignmentNotebook {
                        a(.class("btn action-btn"), .href(assignmentNotebook.editURL)) { "Edit" }
                        " "
                        button(
                            .class("btn action-btn action-danger"), .type(.button),
                            .data("ck-click-target", value: "js-clear-assignment-notebook")
                        ) { "Clear" }
                    } else {
                        button(.class("btn action-btn"), .type(.button), .id("upload-assignment-notebook-btn")) {
                            "Upload"
                        }
                        " "
                        button(
                            .class("btn action-btn"), .type(.button),
                            .data("ck-click-target", value: "js-create-assignment-notebook")
                        ) { "Create Blank" }
                    }
                }
            }
        }
    }

    private var solutionRow: some HTML {
        tr {
            td { strong { "Solution Notebook" } }
            td { NotebookLink(notebook: solutionNotebook, codeID: "solution-notebook-name") }
            td(.class("time")) {
                div(.class("cell-actions")) {
                    if let solutionNotebook {
                        a(.class("btn action-btn"), .href(solutionNotebook.editURL)) { "Edit" }
                        " "
                        button(
                            .class("btn action-btn action-danger"), .type(.button),
                            .data("ck-click-target", value: "js-clear-solution-notebook")
                        ) { "Clear" }
                    } else {
                        button(.class("btn action-btn"), .type(.button), .id("upload-solution-notebook-btn")) {
                            "Upload"
                        }
                        " "
                        button(
                            .class("btn action-btn"), .type(.button),
                            .data("ck-click-target", value: "js-create-solution-notebook")
                        ) { "Create Blank" }
                        if assignmentNotebook != nil {
                            // Only meaningful once an assignment notebook
                            // exists: it copies that notebook into the draft
                            // solution path.
                            " "
                            button(
                                .class("btn action-btn"), .type(.button),
                                .title("Copy the assignment notebook as a starting point for the solution"),
                                .data("ck-click-target", value: "js-create-solution-from-assignment")
                            ) { "Create from Assignment" }
                        }
                    }
                }
            }
        }
    }
}

/// A notebook's name linked to its editor, or "not set".
private struct NotebookLink: HTML {
    let notebook: NewAssignmentNotebookContext?
    let codeID: String

    var body: some HTML {
        if let notebook {
            a(.href(notebook.editURL)) { code(.id(codeID)) { notebook.name } }
        } else {
            code(.class("card-meta")) { "— not set —" }
        }
    }
}

/// The draft's Test Suite: the add-section form, the hidden Generate Starter
/// Tests panel, and the section shells.
private struct NewAssignmentSuiteBlock: HTML {
    let draftID: String
    let rows: [SuiteSectionShellRow]
    let csrfToken: String

    var body: some HTML {
        div(.class("form form--wide suite-editor-section")) {
            div(.class("editor-block-head")) {
                h2 { "Test Suite" }
                div(.class("toolbar toolbar--end")) {
                    details(.class("add-section-details popup-anchor"), .id("add-suite-section-details")) {
                        summary(.class("btn action-btn summary-btn")) { "+ Section" }
                        div(.class("add-section-popup card suite-section-popup")) {
                            form(
                                .method(.post), .action("/instructor/new/draft/suite-sections?draftID=\(draftID)"),
                                .class("form popup-form")
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
            generateTestsPanel
            // The section forms keep a plain redirect: this page is never a
            // workbench pane.
            SuiteSections(
                rows: rows, actionBase: "/instructor/new/draft/suite-sections", actionQuery: "?draftID=\(draftID)",
                formsInPlace: false, csrfToken: csrfToken)
        }
    }

    /// Shown by the page script when a solution notebook is present.
    private var generateTestsPanel: some HTML {
        div(.id("gen-tests-panel"), .class("gen-tests-panel"), .custom(name: "style", value: "display:none")) {
            div(.class("gen-tests-row")) {
                span(.class("gen-tests-title")) { "Generate Starter Tests" }
                " "
                button(.class("btn btn-sm"), .type(.button), .id("scan-solution-btn")) {
                    "Scan Solution for Functions"
                }
                " "
                span(
                    .id("scan-status"), .class("editor-status"), .role("status"),
                    .custom(name: "aria-live", value: "polite")
                ) {}
            }
            div(.id("scan-results"), .custom(name: "style", value: "display:none")) {
                p(.class("card-meta gen-tests-prompt")) { "Select the functions to generate starter tests for:" }
                div(.id("fn-checklist"), .class("fn-checklist")) {}
                div(.class("gen-template-row")) {
                    label(.class("gen-template-label")) {
                        "Template: "
                        select(.id("gen-template-select"), .class("form-input select-xs")) {
                            option(.value("py:differential"), .selected) { "Differential (reference solution)" }
                        }
                        " "
                    }
                }
                button(.class("btn btn-primary btn-compact"), .type(.button), .id("add-gen-tests-btn")) {
                    "Add Selected Tests to Suite"
                }
            }
        }
    }
}
