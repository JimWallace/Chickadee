// APIServer/Views/Pages/SessionAttendancePage.swift
//
// GET /testsetups/:id/sessions/attendance?group=: who joined a lab group's
// session, for course staff (docs/lab-groups.md, "Presence"). It shows names,
// so the present page opens it in a new tab, off the projector. Remove takes
// a student who is not in the room out of the session.

import Elementary

struct SessionAttendancePage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let assignmentTitle: String
    let groupName: String
    let testSetupID: String
    let groupID: String
    let isOpen: Bool
    /// False in an archived course, which is read-only.
    let canRemove: Bool
    let rows: [SessionAttendeeRow]

    private var joinedCount: Int { rows.filter { !$0.isRemoved }.count }
    /// Remove needs an open session in a course that is not archived.
    private var showsActions: Bool { canRemove && isOpen }

    var body: some HTML {
        BaseLayout(title: "Who joined — \(groupName)", page: page, flash: flash) {
            div(.class("page-titlebar")) {
                h1 { "Who joined — \(groupName)" }
            }
            p(.class("page-subtitle")) {
                "\(assignmentTitle) · \(joinedCount) joined\(isOpen ? "" : " · session ended")"
            }
            section(.class("page-section")) {
                if rows.isEmpty {
                    p(.class("empty")) { "No student has joined this run of the session." }
                } else {
                    table(.class("results-table")) {
                        thead {
                            tr {
                                th { "Student" }
                                th { "Username" }
                                th { "Joined" }
                                if showsActions { th { "Actions" } }
                            }
                        }
                        tbody {
                            for row in rows {
                                SessionAttendeeTableRow(
                                    row: row, testSetupID: testSetupID, groupID: groupID,
                                    showsActions: showsActions, csrfToken: page.csrfToken)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One student who joined.
struct SessionAttendeeRow: Sendable {
    let userID: String
    let name: String
    let username: String
    let joinedAtText: String
    let isRemoved: Bool
}

/// One joined student, muted once removed, with the Remove action while the
/// session is open.
struct SessionAttendeeTableRow: HTML {
    let row: SessionAttendeeRow
    let testSetupID: String
    let groupID: String
    let showsActions: Bool
    let csrfToken: String

    var body: some HTML {
        tr {
            td { row.name }
            td { row.username }
            td { row.joinedAtText }
            if showsActions { actions }
        }
        .attributes(.class("row-muted"), when: row.isRemoved)
    }

    private var actions: some HTML {
        td {
            if row.isRemoved {
                span(.class("text-muted")) { "Removed" }
            } else {
                form(
                    .method(.post), .action("/testsetups/\(testSetupID)/sessions/remove"),
                    .class("inline-form"),
                    .data("confirm", value: "Remove \(row.name)? They cannot join again until the session restarts.")
                ) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("groupID"), .value(groupID))
                    input(.type(.hidden), .name("userID"), .value(row.userID))
                    button(.class("btn action-btn action-danger"), .type(.submit)) { "Remove" }
                }
            }
        }
    }
}
