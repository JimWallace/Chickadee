// APIServer/Views/Pages/SlipDayConfirmPage.swift
//
// GET /testsetups/:testSetupID/slip-day: the confirmation before a student
// spends a slip day (#1228). It names the new deadline, the cost against the
// balance, and that the spend cannot be undone by the student.

import Elementary

struct SlipDayConfirmPage: HTML {
    let page: PageRequestContext
    let testSetupID: String
    let assignmentTitle: String
    let courseCode: String
    /// True when this claim stacks on an existing slip-day extension.
    let isStacked: Bool
    /// The deadline the student holds now: the original due date for a first
    /// claim, the current slip-day extension for a stacked one.
    let heldDeadlineText: String
    let newDeadlineText: String
    let balance: Int
    let totalBudget: Int
    let remainingAfter: Int
    let extensionHours: Int

    private var confirmLabel: String {
        isStacked ? "Use another slip day" : "Use a slip day"
    }

    var body: some HTML {
        BaseLayout(title: "Use a slip day", page: page) {
            PageStyle(
                """
                .slip-day-confirm-card { max-width: 42rem; padding: 1rem; border: 1px solid var(--border); border-radius: var(--radius-lg); background: var(--surface-muted); }
                .slip-day-confirm-title { margin: 0 0 .5rem; }
                .slip-day-confirm-deadline { font-size: var(--text-lg); }
                .slip-day-confirm-actions { display: flex; gap: .5rem; align-items: center; margin-top: 1rem; }
                """
            )
            h1 { "Use a slip day" }
            div(.class("slip-day-confirm-card")) {
                h2(.class("slip-day-confirm-title")) { assignmentTitle }
                if isStacked {
                    p {
                        "You currently hold a slip-day extension until "
                        strong { heldDeadlineText }
                        " on this assignment."
                    }
                    p(.class("slip-day-confirm-deadline")) {
                        "Spending another slip day extends your personal deadline to "
                        strong { newDeadlineText }
                        " (America/Toronto)."
                    }
                } else {
                    p {
                        "The deadline for this assignment passed on "
                        strong { heldDeadlineText }
                        "."
                    }
                    p(.class("slip-day-confirm-deadline")) {
                        "Spending a slip day extends your personal deadline to "
                        strong { newDeadlineText }
                        " (America/Toronto)."
                    }
                }
                p {
                    "This uses "
                    strong { "1 of your \(balance) remaining" }
                    " slip days for \(courseCode) (\(remainingAfter) of \(totalBudget) will remain). Each slip day "
                        + "adds \(extensionHours) hours, counted from the original deadline."
                }
                p { "A spent slip day cannot be returned by you. Course staff can refund one in exceptional cases." }
                div(.class("slip-day-confirm-actions")) {
                    form(.method(.post), .action("/testsetups/\(testSetupID)/slip-day"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        button(.class("btn btn-primary"), .type(.submit)) { confirmLabel }
                    }
                    a(.class("btn"), .href("/")) { "Cancel" }
                }
            }
        }
    }
}
