// APIServer/Views/PresentSessionControls.swift
//
// The present page's session controls for a per-group activity
// (docs/lab-groups.md, slice 2): which lab group the projector is for, the
// button that starts, ends or reopens its session, and the link to who
// joined. For the presenter, so they sit in the corner toolbar beside Back
// and Full screen, and go away in full screen with it.

import Elementary

struct PresentSessionControls: HTML {
    let panel: GroupSessionPanel
    let boardURL: String
    let csrfToken: String

    var body: some HTML {
        form(.method(.get), .action(boardURL), .class("inline-form form-flush")) {
            input(.type(.hidden), .name("present"), .value("1"))
            label(.class("visually-hidden"), .for("present-group")) { "Lab group" }
            select(.id("present-group"), .name("group"), .class("form-input"), .dataFlag("ck-submit-on-change")) {
                for choice in panel.groups {
                    option(.value(choice.id)) { choice.name }
                        .attributes(.selected, when: choice.id == panel.selectedGroupID)
                }
            }
        }
        " "
        form(
            .method(.post),
            .action("/testsetups/\(panel.testSetupID)/sessions/\(panel.isOpen ? "end" : "start")"),
            .class("inline-form form-flush")
        ) {
            CSRFField(token: csrfToken)
            input(.type(.hidden), .name("groupID"), .value(panel.selectedGroupID))
            if panel.isOpen {
                button(.class("btn action-btn"), .type(.submit)) { "End session" }
            } else {
                button(.class("btn btn-primary"), .type(.submit)) {
                    panel.hasStarted ? "Reopen session" : "Start session"
                }
            }
        }
        if panel.hasStarted {
            " "
            // Names, so off the projector: the presenter opens it elsewhere.
            NewTabLink(href: panel.attendanceURL, text: "Who joined", attributes: [.class("btn action-btn")])
        }
    }
}

/// The join address and code, large enough to read from the back of a lab,
/// with how long the code shows and how many joined. Rendered inline and as
/// the `?fragment=join` refresh.
struct PresentJoinCode: HTML {
    let groupName: String
    let address: String
    let code: String
    let secondsLeft: Int
    let joinedCount: Int

    /// Nil while the session is not open, so the box is empty.
    init?(panel: GroupSessionPanel) {
        guard let code = panel.joinCode else { return nil }
        self.groupName = panel.groupName
        self.address = panel.joinAddress
        self.code = code
        self.secondsLeft = panel.secondsLeft
        self.joinedCount = panel.joinedCount
    }

    var body: some HTML {
        div(.class("present-join")) {
            span(.class("present-clock-label")) { "\(groupName) · join at" }
            // Outside the uppercased label: the room types the address.
            span(.class("present-join-address")) { address }
            span(.class("present-join-code")) { code }
            span(.class("present-clock-label")) {
                "New code in \(secondsLeft) \(secondsLeft == 1 ? "second" : "seconds") · \(joinedCount) joined"
            }
        }
    }
}
