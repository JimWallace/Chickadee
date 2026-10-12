// APIServer/Views/CourseFields.swift
//
// The fields of one course form: the admin new-course form, a course's
// settings and clone forms, and the instructor New term tab. Each copy takes
// its own id prefix (`CourseFieldsContext`), so every copy on a page has
// unique ids. A validation error shows here, beside the form it belongs to.

import Elementary

struct CourseFields: HTML {
    let form: CourseFieldsContext

    var body: some HTML {
        if let error = form.error {
            div(.class("form-error"), .role("alert")) { error }
        }
        div(.class("toolbar")) {
            div(.class("field-stack field-stack--narrow")) {
                label(.for("\(form.idPrefix)-code")) { "Code" }
                input(
                    .id("\(form.idPrefix)-code"), .class("form-input"), .type(.text), .name("code"),
                    .value(form.code), .placeholder("e.g. CS136"), .required
                )
                .attributes(.autofocus, when: form.autofocus)
            }
            div(.class("field-stack field-stack--grow")) {
                label(.for("\(form.idPrefix)-name")) { "Name" }
                input(
                    .id("\(form.idPrefix)-name"), .class("form-input"), .type(.text), .name("name"),
                    .value(form.name), .placeholder("e.g. Elementary Algorithm Design"), .required)
            }
        }
        div(.class("toolbar")) {
            div(.class("field-stack field-stack--narrow")) {
                label(.for("\(form.idPrefix)-year")) { "Year" }
                select(.id("\(form.idPrefix)-year"), .class("form-input"), .name("termYear"), .required) {
                    for option in form.yearOptions {
                        Elementary.option(.value(option.value)) { option.label }
                            .attributes(.selected, when: option.selected)
                    }
                }
            }
            div(.class("field-stack field-stack--narrow")) {
                label(.for("\(form.idPrefix)-term")) { "Term" }
                select(.id("\(form.idPrefix)-term"), .class("form-input"), .name("termSeason"), .required) {
                    if form.asksForTerm {
                        option(.value(""), .selected, .disabled) { "Choose" }
                    }
                    for option in form.termOptions {
                        Elementary.option(.value(option.value)) { option.label }
                            .attributes(.selected, when: option.selected)
                    }
                }
            }
        }
    }
}
