// APIServer/Views/RowMenu.swift
//
// The "More actions" menu at the end of a table row: a disclosure whose
// summary is the ⋯ button, and a popover panel of menu items. The items are
// the caller's (`row-menu-item` buttons and links); the shell is written here
// and nowhere else (SwiftLint `elementary_row_menu_only_in_component`).

import Elementary

struct RowMenu<Items: HTML>: HTML {
    /// What the menu acts on, for the button's accessible name.
    let subject: String
    let items: Items

    init(for subject: String, @HTMLBuilder items: () -> Items) {
        self.subject = subject
        self.items = items()
    }

    var body: some HTML {
        details(.class("ext-details row-menu")) {
            summary(
                .class("btn action-btn action-btn-icon ext-summary"), .title("More actions"),
                .ariaLabel("More actions for \(subject)")
            ) {
                Icon("i-more")
            }
            div(.class("popover-panel row-menu-panel"), .role("menu")) {
                items
            }
        }
    }
}
