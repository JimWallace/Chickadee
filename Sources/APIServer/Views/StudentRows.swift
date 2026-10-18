// APIServer/Views/StudentRows.swift
//
// The rows of the instructor roster's students table. `InstructorStudentsPage`
// renders them in the table, and `GET /instructor/students-data?fragment=rows`
// renders them alone for `table-poll.js`. Both render this one struct, so the
// poll cannot drift from the page. A row's bird needs the avatar sprite, which
// the page renders once.

import Elementary

struct StudentRows: HTML {
    let students: [EnrolledStudentRow]
    /// True when the viewer may not change the roster: an archived course, or
    /// a TA. Every mutating control is gated on it.
    let rosterReadOnly: Bool
    let csrfToken: String
    /// True when the course has a group set: each row then has a Group cell.
    var showsGroups = false

    var body: some HTML {
        for student in students {
            StudentRow(
                student: student, rosterReadOnly: rosterReadOnly, csrfToken: csrfToken, showsGroups: showsGroups)
        }
    }
}

/// One student, or one pending pre-enrolment: bird, name, role, last seen and
/// the row actions.
private struct StudentRow: HTML {
    let student: EnrolledStudentRow
    let rosterReadOnly: Bool
    let csrfToken: String
    let showsGroups: Bool

    var body: some HTML {
        tr(.class("js-student-row-link"), .data("student-id", value: student.id)) {
            td(.class("item-tile-cell")) {
                if let avatar = student.avatar {
                    Avatar(avatar: avatar)
                } else {
                    span(.class("item-tile")) { Icon("i-calendar") }
                }
            }
            td(.class("item-main"), .data("sort-value", value: student.displayName)) {
                nameCell
            }
            td(.class("item-status")) {
                if student.isPending {
                    span(.class("tier tier-preview")) { "Pending" }
                } else if rosterReadOnly {
                    student.role
                } else if let roleSelect = student.roleSelect {
                    RoleSelect(cell: roleSelect, csrfToken: csrfToken)
                }
            }
            if showsGroups {
                // Sort by the group's name: a select would sort by its value, the group id.
                td(.class("col-hide-phone"), .data("sort-value", value: student.groupName ?? "")) {
                    if !rosterReadOnly, let groupSelect = student.groupSelect {
                        GroupSelect(cell: groupSelect, csrfToken: csrfToken)
                    } else if let groupName = student.groupName {
                        groupName
                    }
                }
            }
            if let iso = student.lastSeenAtISO {
                td(.class("col-hide-phone js-relative-time"), .data("iso", value: iso)) { student.lastSeenAtText }
            } else {
                td(.class("col-hide-phone js-relative-time")) { student.lastSeenAtText }
            }
            td(.class("item-actions-td")) {
                if !rosterReadOnly {
                    div(.class("assignment-actions-cell")) {
                        if student.isPending {
                            registerPanel
                        } else {
                            a(
                                .class("btn action-btn action-btn-icon"), .href(student.submissionsURL),
                                .title("View \(student.displayName)'s submissions"),
                                .ariaLabel("View \(student.displayName)'s submissions")
                            ) {
                                Icon("i-eye")
                            }
                        }
                        rowMenu
                    }
                }
            }
        }
        .attributes(.class("js-student-row-pending"), when: student.isPending)
        .attributes(.data("href", value: student.submissionsURL), when: !student.isPending)
    }

    @HTMLBuilder private var nameCell: some HTML {
        if student.isPending {
            div(.class("item-title text-muted")) { em { student.displayName } }
            div(.class("item-details")) { student.pendingNote }
        } else {
            div(.class("item-title")) {
                a(.href(student.submissionsURL)) { student.displayName }
                if let learnFlag = student.learnFlag {
                    " "
                    span(.class("tier tier-danger"), .title("LEARN grade sync cannot reach this student")) {
                        learnFlag
                    }
                }
            }
            div(.class("item-details")) {
                code { student.username }
                if showsGroups, let groupName = student.groupName {
                    " "
                    span(.class("row-phone-meta")) { groupName }
                }
                if student.learnFlag != nil {
                    " · \(student.learnFlagReason ?? "") · \(student.learnFlagAdvice ?? "")"
                }
            }
        }
    }

    /// The pending row's Register panel: materialise the pre-enrolment now.
    private var registerPanel: some HTML {
        details(.class("ext-details form-flush")) {
            summary(
                .class("btn action-btn ext-summary"), .title("Register this student now"),
                .ariaLabel("Register pending student")
            ) {
                "Register"
            }
            form(.method(.post), .action(student.registerURL), .class("ext-panel")) {
                CSRFField(token: csrfToken)
                p(.class("section-note")) {
                    "Create a real account for "
                    code { student.username }
                    " now, for grade-sync testing; their real login adopts it."
                }
                label(.class("ext-field-label")) {
                    "Display name "
                    input(
                        .type(.text), .name("displayName"), .placeholder(student.username), .class("ext-field-input"))
                }
                label(.class("ext-field-label")) {
                    "Student number (optional) "
                    input(.type(.text), .name("studentID"), .class("ext-field-input"))
                }
                label(.class("ext-field-label")) {
                    "Email (optional) "
                    input(.type(.email), .name("email"), .class("ext-field-input"))
                }
                label(.class("ext-field-label")) {
                    "SSO subject (optional) "
                    input(
                        .type(.text), .name("externalSubject"), .placeholder("leave blank to adopt by username"),
                        .class("ext-field-input"))
                }
                div(.class("ext-panel-actions")) {
                    button(.class("btn action-btn"), .type(.submit)) { "Register" }
                }
            }
        }
    }

    private var rowMenu: some HTML {
        RowMenu(for: student.displayName) {
            if !student.isPending {
                form(
                    .method(.post), .action(student.newHandleURL),
                    .data(
                        "confirm",
                        value:
                            "Give @\(student.username) a new class handle? They will see the new handle on their account page and on leaderboards."
                    )
                ) {
                    CSRFField(token: csrfToken)
                    button(.class("row-menu-item"), .type(.submit), .role("menuitem")) {
                        Icon("i-refresh")
                        "Give new handle"
                    }
                }
            }
            form(
                .method(.post), .action(student.unenrollURL),
                .data("confirm", value: "Remove @\(student.username) from this course?")
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    Icon("i-trash")
                    "Remove from course"
                }
            }
        }
    }
}
