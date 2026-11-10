// APIServer/Views/AssignmentTypeTile.swift
//
// The row tile of a published assignment, by its declared type
// (docs/assignment-types.md): a teal clipboard for an Assignment, an indigo
// flask for a Lab and a magenta group for a Class activity.

import Core
import Elementary

/// The `.item-tile` of a published assignment's course row.
struct AssignmentTypeTile: HTML {
    let type: AssignmentType

    private var kind: String {
        switch type {
        case .assignment: "graded"
        case .lab: "lab"
        case .classActivity: "activity"
        }
    }

    private var symbol: String {
        switch type {
        case .assignment: "i-clipboard-check"
        case .lab: "i-flask"
        case .classActivity: "i-users"
        }
    }

    var body: some HTML {
        // The icon is aria-hidden, so the type's name is the tile's text for a
        // screen reader; the hover title repeats it for a pointer.
        span(.class("item-tile"), .data("kind", value: kind), .title(type.displayName)) {
            Icon(symbol)
            span(.class("visually-hidden")) { type.displayName }
        }
    }
}
