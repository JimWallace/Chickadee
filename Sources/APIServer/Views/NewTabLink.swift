// APIServer/Views/NewTabLink.swift
//
// A link that opens in a new tab, with the external icon and the words that a
// screen reader needs ("Component vocabulary" in docs/ui-design.md).

import Elementary

/// `<a target="_blank">` with the external icon and a hidden
/// "(opens in a new tab)". `attributes` are added to the anchor, for a class
/// or a menu role.
struct NewTabLink: HTML {
    let href: String
    let text: String
    var attributes: [HTMLAttribute<HTMLTag.a>] = []

    var body: some HTML {
        a(attributes: [.href(href), .target(.blank), .rel("noopener noreferrer")] + attributes) {
            text
            Icon("i-external")
            span(.class("visually-hidden")) { "(opens in a new tab)" }
        }
    }
}
