// APIServer/Routes/Web/SelectOption.swift
//
// One `<option>` of a form select, as the templates read it. Every select
// on the web UI renders the same three keys, so every page context uses
// this one type. The functions that build a page's list live beside that
// page's context.

/// One `<option>` of a select: its posted value, its visible text, and
/// whether it is the current choice.
struct SelectOption: Encodable, Equatable {
    let value: String
    let label: String
    let selected: Bool
}
