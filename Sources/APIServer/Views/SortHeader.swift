// APIServer/Views/SortHeader.swift
//
// A sortable column header. sortable-table.js reads the key and the type and
// drives the button.

import Elementary

/// A sortable column header, read by sortable-table.js.
struct SortHeader: HTML {
    let key: String
    let type: String
    let label: String
    var hideOnPhone = false

    var body: some HTML {
        if hideOnPhone {
            th(.class("col-hide-phone"), .data("sort-key", value: key), .data("sort-type", value: type)) {
                button(.class("sort-header"), .type(.button)) { label }
            }
        } else {
            th(.data("sort-key", value: key), .data("sort-type", value: type)) {
                button(.class("sort-header"), .type(.button)) { label }
            }
        }
    }
}
