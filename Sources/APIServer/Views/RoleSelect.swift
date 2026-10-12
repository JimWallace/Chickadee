// APIServer/Views/RoleSelect.swift
//
// One person's course-role select on a roster row. The instructor roster
// (students and staff) and the admin course page render this one view, so the
// three option labels live in one place. The select posts itself on change.

import Elementary

struct RoleSelect: HTML {
    let cell: RoleSelectCell
    let csrfToken: String

    var body: some HTML {
        form(.method(.post), .action(cell.action), .class("inline-form form-flush")) {
            CSRFField(token: csrfToken)
            label(.class("visually-hidden"), .for("role-\(cell.userID)")) { "Role for \(cell.personName)" }
            span(.class("state-select"), .data("state", value: cell.role)) {
                select(
                    .id("role-\(cell.userID)"), .name("role"), .class("form-input"), .dataFlag("ck-submit-on-change")
                ) {
                    option(.value("student")) { "Student" }
                        .attributes(.selected, when: cell.role == "student")
                    option(.value("ta")) { "TA" }
                        .attributes(.selected, when: cell.role == "ta")
                    option(.value("instructor")) { "Instructor" }
                        .attributes(.selected, when: cell.role == "instructor")
                }
            }
        }
    }
}
