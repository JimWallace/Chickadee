// APIServer/Routes/Web/StaffFieldsContext.swift
//
// The sub-context of `_staff-fields.leaf`: the identifier and role fields of a
// staff form. The instructor roster and the admin course page render the same
// partial, as the course forms share `_course-fields` (CourseFieldsContext).

import Core

struct StaffFieldsContext: Encodable {
    /// Makes each copy's element ids unique on the page.
    let idPrefix: String
    /// The one-sentence note under the identifier field.
    let note: String
    let roleOptions: [SelectOption]
    /// The refusal to show above the fields, or nil.
    let error: String?

    /// - Parameters:
    ///   - placeholderAllowed: True when a person with no account can be added.
    ///   - defaultRole: The role the select opens on.
    ///   - errorQuery: The `staffError` query value (`StaffFormError`).
    init(idPrefix: String, placeholderAllowed: Bool, defaultRole: CourseRole, errorQuery: String?) {
        self.idPrefix = idPrefix
        self.note =
            placeholderAllowed
            ? "Use a username for someone who has not signed in."
            : "The person must already have an account."
        self.roleOptions = [CourseRole.ta, .instructor].map { role in
            SelectOption(
                value: role.rawValue, label: role == .ta ? "TA" : "Instructor", selected: role == defaultRole)
        }
        self.error = StaffFormError.message(forQuery: errorQuery)
    }
}
