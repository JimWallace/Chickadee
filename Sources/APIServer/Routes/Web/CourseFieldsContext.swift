// APIServer/Routes/Web/CourseFieldsContext.swift
//
// The values of one course form, rendered by `_course-fields.leaf`. Four forms
// share the partial: the admin new-course form, the settings and clone forms
// on an admin course page, and the instructor New term tab (#1974).

import Core

struct CourseFieldsContext: Encodable {
    /// Makes each copy's element ids unique on the page.
    let idPrefix: String
    let code: String
    let name: String
    let yearOptions: [SelectOption]
    let termOptions: [SelectOption]
    /// True when no term is chosen yet: the term select opens on a disabled
    /// "Choose", so a form cannot post a season nobody picked.
    let asksForTerm: Bool
    /// The refusal to show above the fields, or nil.
    let error: String?
    /// True on the new-course form, where the code is the first thing typed.
    let autofocus: Bool

    /// A form with `term` selected. With no term the year select falls back to
    /// the current year and the term select asks.
    init(
        idPrefix: String, code: String, name: String, term: AcademicTerm?,
        error: String? = nil, autofocus: Bool = false
    ) {
        self.idPrefix = idPrefix
        self.code = code
        self.name = name
        self.yearOptions = CourseTermForm.yearOptions(selected: term?.year)
        self.termOptions = CourseTermForm.options(selected: term?.season)
        self.asksForTerm = term == nil
        self.error = error
        self.autofocus = autofocus
    }
}
