// APIServer/Views/LabGroupSelect.swift
//
// The one "pick a lab group" control (docs/lab-groups.md): a GET form whose
// select reloads `action` with `?group=<id>` on change. The present page's
// session controls and the leaderboard's group control both use it.

import Elementary

struct LabGroupSelect: HTML {
    let id: String
    let action: String
    let options: [GroupOption]
    let selectedID: String?
    /// Query fields the page needs to keep, such as `present=1`.
    var keep: [(name: String, value: String)] = []

    var body: some HTML {
        form(.method(.get), .action(action), .class("inline-form form-flush")) {
            for field in keep {
                input(.type(.hidden), .name(field.name), .value(field.value))
            }
            label(.class("visually-hidden"), .for(id)) { "Lab group" }
            select(.id(id), .name("group"), .class("form-input"), .dataFlag("ck-submit-on-change")) {
                for choice in options {
                    option(.value(choice.id)) { choice.name }
                        .attributes(.selected, when: choice.id == selectedID)
                }
            }
        }
    }
}
