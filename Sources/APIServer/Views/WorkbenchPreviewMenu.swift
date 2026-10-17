// APIServer/Views/WorkbenchPreviewMenu.swift
//
// "Preview as student ▾" in the workbench's view switch (notebook views
// NB6b): a menu of the course's students. Each item opens the assignment
// notebook as that student gets it, read-only. workbench.js swaps the
// notebook in place, as it does for Solution and Starter, and names the
// student on the menu button from `data-wb-label`.

import Elementary

struct WorkbenchPreviewMenu: HTML {
    let students: [WorkbenchPreviewStudent]
    /// The student the notebook shows now, or nil.
    let previewed: WorkbenchPreviewStudent?

    static let idleLabel = "Preview as student ▾"

    /// The menu button's label while `name`'s notebook is open.
    static func label(for name: String) -> String { "Preview: \(name) ▾" }

    var body: some HTML {
        details(.class("ext-details popup-anchor wb-preview-menu")) {
            // The title holds the whole name of a long one, which the button
            // cuts; with no preview open there is nothing more to say.
            summary(.class("btn action-btn ext-summary"), .data("wb-idle-label", value: Self.idleLabel)) {
                previewed.map { Self.label(for: $0.name) } ?? Self.idleLabel
            }
            .attributes(.title(previewed?.name ?? ""), when: previewed != nil)
            div(.class("popover-panel wb-preview-panel"), .role("menu")) {
                for student in students {
                    button(
                        .class("row-menu-item wb-view"), .type(.button), .role("menuitemradio"),
                        .data("wb-target-file", value: "assignment"),
                        .data("wb-target-view", value: "student:\(student.token)"),
                        .data("wb-label", value: Self.label(for: student.name)),
                        .custom(name: "aria-checked", value: previewed == student ? "true" : "false")
                    ) { student.name }
                }
            }
        }
    }
}
