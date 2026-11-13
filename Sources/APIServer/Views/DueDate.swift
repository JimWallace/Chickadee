// APIServer/Views/DueDate.swift
//
// The one rendering of a student's due date (docs/ui-design.md §"Timestamps",
// "Due dates"; UI audit #3007, finding 10): the word "Due", the relative
// reading ("in 3 days"), then the absolute time. The relative span is seeded
// with the absolute text as its no-JS fallback.

import Elementary

struct DueDate: HTML {
    /// The deadline as ISO 8601, for `relative-time.js`.
    let iso: String
    /// The deadline as the server formats it.
    let text: String
    /// A short qualifier after the date, such as "(extension)".
    var note: String?

    var body: some HTML {
        "Due "
        span(.class("js-relative-time"), .data("iso", value: iso)) { text }
        " · \(text)"
        if let note {
            " "
            span(.class("card-meta")) { note }
        }
    }
}
