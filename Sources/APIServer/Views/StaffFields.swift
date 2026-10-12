// APIServer/Views/StaffFields.swift
//
// The fields of one staff form: the instructor roster's and the admin course
// page's. Each copy takes its own id prefix (`StaffFieldsContext`), so every
// copy on a page has unique ids. A refusal shows here, beside the form it
// belongs to.

import Elementary

struct StaffFields: HTML {
    let form: StaffFieldsContext

    var body: some HTML {
        if let error = form.error {
            div(.class("form-error"), .role("alert")) { error }
        }
        div(.class("toolbar")) {
            div(.class("field-stack field-stack--grow")) {
                label(.for("\(form.idPrefix)-identifier")) { "Username or email" }
                input(
                    .id("\(form.idPrefix)-identifier"), .class("form-input"), .type(.text), .name("identifier"),
                    .required, .autocomplete("off"), .custom(name: "aria-describedby", value: "\(form.idPrefix)-note"))
            }
            div(.class("field-stack field-stack--narrow")) {
                label(.for("\(form.idPrefix)-role")) { "Role" }
                select(.id("\(form.idPrefix)-role"), .class("form-input"), .name("role")) {
                    for option in form.roleOptions {
                        Elementary.option(.value(option.value)) { option.label }
                            .attributes(.selected, when: option.selected)
                    }
                }
            }
        }
        p(.class("field-note"), .id("\(form.idPrefix)-note")) { form.note }
    }
}
