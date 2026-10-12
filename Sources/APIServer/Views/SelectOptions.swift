// APIServer/Views/SelectOptions.swift
//
// The `<option>` list of a select built from `SelectOption` values, with the
// chosen one marked `selected`.

import Elementary

struct SelectOptions: HTML {
    let options: [SelectOption]

    var body: some HTML {
        for choice in options {
            option(.value(choice.value)) { choice.label }
                .attributes(.selected, when: choice.selected)
        }
    }
}
