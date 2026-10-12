// APIServer/Views/GradeOverrideMenu.swift
//
// The inline grade-override control on the staff submission tables: the
// assignment roster (`AssignmentSubmissionsPage`) and one student's course
// view (`StudentAssignmentTable`).

import Elementary

/// A scissors button that opens a form to set, edit or clear a student's
/// grade override.
struct GradeOverrideMenu: HTML {
    let isOverridden: Bool
    /// The prefill: the active override, else the best grade, else 0.
    let percent: Int
    let savePath: String
    let clearPath: String
    /// `ext-panel` on the roster, `popover-panel` on the student's view.
    let panelClass: String
    /// Where the action redirects afterwards, when the route reads one.
    let returnTo: String?
    let csrfToken: String

    var body: some HTML {
        details(.class("ext-details form-flush")) {
            summary(
                .class("btn action-btn action-btn-icon ext-summary"),
                .title(isOverridden ? "Edit this student’s grade override" : "Override this student’s grade"),
                .ariaLabel(isOverridden ? "Edit grade override" : "Override grade")
            ) {
                Icon("i-scissors")
            }
            .attributes(.class("grade-override-active"), when: isOverridden)
            form(.method(.post), .action(savePath), .class(panelClass)) {
                CSRFField(token: csrfToken)
                " "
                if let returnTo {
                    input(.type(.hidden), .name("returnTo"), .value(returnTo))
                    " "
                }
                label(.class("ext-field-label")) {
                    "Override grade (%)"
                    input(
                        .type(.number), .name("overridePercent"), .min(0), .max(100), .step(1),
                        .value(String(percent)), .required, .class("ext-field-input"))
                    " "
                }
                " "
                label(.class("ext-field-label")) {
                    "Note (optional)"
                    input(.type(.text), .name("note"), .placeholder("Reason for override"), .class("ext-field-input"))
                    " "
                }
                div(.class("ext-panel-actions")) {
                    button(.class("btn action-btn"), .type(.submit)) { "Save" }
                    if isOverridden {
                        " "
                        button(
                            .class("btn action-btn"), .type(.submit), .custom(name: "formaction", value: clearPath),
                            .init(name: "formnovalidate", value: nil),
                            .data(
                                "confirm",
                                value: "Clear this student’s grade override and revert to the auto-graded result?")
                        ) { "Clear" }
                    }
                }
            }
        }
    }
}
