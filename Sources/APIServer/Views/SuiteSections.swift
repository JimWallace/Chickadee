// APIServer/Views/SuiteSections.swift
//
// The server-rendered suite section shells, shared by the Create Assignment
// page and the assignment edit body.
//
// Each `.section-block` owns its own table shell. suite-table.js fills the
// `tbody[data-section-id]` rows from the JSON seed and keeps them in sync
// through the debounced whole-suite write. Section CRUD (create, rename,
// delete, reorder) goes through per-page endpoints, which is the only thing
// that differs between the two surfaces:
//
//   actionBase   the /suite-sections prefix for this page
//   actionQuery  a trailing query string ("?draftID=..." on the create page,
//                empty on the edit page)
//   formsInPlace whether the per-section forms carry `data-ck-inplace`, which
//                makes inplace-forms.js re-render a workbench pane instead of
//                following the handler's redirect
//
// An ungrouped block has no header to host the inline buttons, so it gets a
// slim per-section toolbar instead.

import Elementary

struct SuiteSections: HTML {
    let rows: [SuiteSectionShellRow]
    let actionBase: String
    let actionQuery: String
    let formsInPlace: Bool
    let csrfToken: String

    var body: some HTML {
        div(.id("suite-sections")) {
            for row in rows {
                SuiteSectionBlock(
                    row: row, actionBase: actionBase, actionQuery: actionQuery, formsInPlace: formsInPlace,
                    csrfToken: csrfToken)
            }
        }
    }
}

private struct SuiteSectionBlock: HTML {
    let row: SuiteSectionShellRow
    let actionBase: String
    let actionQuery: String
    let formsInPlace: Bool
    let csrfToken: String

    private func action(_ op: String) -> String {
        "\(actionBase)/\(row.sectionID)/\(op)\(actionQuery)"
    }

    var body: some HTML {
        div(.class("section-block"), .data("section-id", value: row.sectionID)) {
            if !row.isUngrouped {
                header
                variablesForm
            } else {
                div(.class("section-create-toolbar"), .data("section-id", value: row.sectionID)) {
                    addTestButton
                }
            }
            table(.class("results-table")) {
                tbody(.data("section-id", value: row.sectionID)) {}
            }
        }
    }

    private var addTestButton: some HTML {
        button(
            .type(.button), .class("btn action-btn btn-xs js-section-add-test-btn"),
            .data("section-id", value: row.sectionID)
        ) { "+ Add Test" }
    }

    private var header: some HTML {
        div(.class("section-header"), .draggable(.true)) {
            span(.class("section-drag-handle"), .ariaHidden) { "⋮⋮" }
            div(.class("section-view")) {
                strong { row.name }
                " "
                button(
                    .class("btn-link js-section-edit-toggle icon-btn-text"), .type(.button), .title("Edit section"),
                    .ariaLabel("Edit section")
                ) {
                    " "
                    Icon("i-pencil")
                    " "
                }
                " "
                span(.class("section-spacer")) {}
                " "
                button(
                    .type(.button), .class("btn action-btn btn-xs js-section-var-add"),
                    .data("section-id", value: row.sectionID)
                ) { "+ Add Input" }
                " "
                addTestButton
            }
            // Shown by suite-table.js when the pencil is clicked.
            div(.class("section-edit"), .custom(name: "style", value: "display:none")) {
                form(
                    attributes: [.class("section-rename-form"), .method(.post), .action(action("rename"))]
                        + (formsInPlace ? [.dataFlag("ck-inplace")] : [])
                ) {
                    CSRFField(token: csrfToken)
                    " "
                    input(
                        .class("form-input section-name-input"), .type(.text), .name("name"), .value(row.name),
                        .required)
                    " "
                    button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Save" }
                }
                button(
                    .class("btn action-btn action-danger js-section-delete-btn"), .type(.button),
                    .data("action", value: action("delete")), .data("name", value: row.name)
                ) { "Delete" }
                " "
                button(
                    .class("btn-link js-section-edit-cancel icon-btn-text"), .type(.button), .ariaLabel("Cancel"),
                    .title("Cancel")
                ) { "✕" }
            }
        }
    }

    /// The Fixed Inputs table above the Tests table. Every pattern family in
    /// the section can reference these by name, and a family-level variable
    /// shadows a section variable of the same name. section-inputs-editor.js
    /// saves on change (debounced); the main Save button also flushes it.
    private var variablesForm: some HTML {
        form(
            .class("section-vars-form"), .method(.post), .action(action("variables")),
            .data("section-id", value: row.sectionID)
        ) {
            table(.class("results-table section-vars-table")) {
                tbody(.class("js-section-vars-body")) {
                    for variable in row.variables {
                        SectionVariableRow(variable: variable)
                    }
                }
            }
            ValueCueNote()
        }
    }
}

private struct SectionVariableRow: HTML {
    let variable: SuiteSectionVariableShellRow

    var body: some HTML {
        tr(.class("js-section-var-row")) {
            td(.class("section-var-namecell")) {
                span(.class("js-section-var-row-valid section-var-valid")) {}
                " "
                input(
                    .type(.text), .class("form-input cell-input cell-input--with-check input-mono js-section-var-name"),
                    .value(variable.name), .placeholder("Input Name"))
            }
            td {
                input(
                    .type(.text), .class("form-input cell-input input-mono js-section-var-value"),
                    .ariaLabel("Value"), .value(variable.valueJSON), .placeholder(#"[{...}, {...}] or {"k": 1}"#))
            }
            td(.class("section-var-removecell")) {
                button(
                    .type(.button), .class("btn action-btn action-danger icon-btn-xs js-section-var-remove"),
                    .title("Remove input"), .ariaLabel("Remove input")
                ) {
                    Icon("i-trash")
                }
            }
        }
    }
}
