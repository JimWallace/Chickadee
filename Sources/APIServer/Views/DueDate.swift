// APIServer/Views/DueDate.swift
//
// The one rendering of a student's due date (docs/ui-design.md §"Timestamps",
// "Due dates"; UI audit #3007, finding 10): the word "Due", the absolute time,
// then the relative reading ("in 3 days"). The absolute text is the no-JS
// fallback, so the relative span is seeded empty, as in the audit log. Its
// "·" separator comes from CSS (`.due-relative:not(:empty)::before`), so a
// page without JS shows the date once and no stray separator.

import Elementary

struct DueDate: HTML {
    /// The deadline as ISO 8601, for `relative-time.js`.
    let iso: String
    /// The deadline as the server formats it.
    let text: String
    /// A short qualifier after the date, such as "(extension)".
    var note: String?

    var body: some HTML {
        "Due \(text)"
        if !iso.isEmpty {
            " "
            span(.class("due-relative js-relative-time"), .data("iso", value: iso)) {}
        }
        if let note {
            " "
            span(.class("card-meta")) { note }
        }
    }
}
