// APIServer/Views/GroupSelect.swift
//
// The Students tab's group select for one student (docs/lab-groups.md). It
// submits on change, as the role select does.

import Elementary

struct GroupSelect: HTML {
    let cell: GroupSelectCell
    let csrfToken: String

    var body: some HTML {
        form(.method(.post), .action(GroupSelectCell.action), .class("inline-form form-flush")) {
            CSRFField(token: csrfToken)
            input(.type(.hidden), .name("setID"), .value(cell.setID))
            input(.type(.hidden), .name("userID"), .value(cell.userID))
            label(.class("visually-hidden"), .for("group-\(cell.userID)")) { "Group for \(cell.personName)" }
            select(
                .id("group-\(cell.userID)"), .name("groupID"), .class("form-input"), .dataFlag("ck-submit-on-change")
            ) {
                option(.value("")) { "No group" }
                    .attributes(.selected, when: cell.groupID.isEmpty)
                for choice in cell.options {
                    option(.value(choice.id)) { choice.name }
                        .attributes(.selected, when: choice.id == cell.groupID)
                }
            }
        }
    }
}
