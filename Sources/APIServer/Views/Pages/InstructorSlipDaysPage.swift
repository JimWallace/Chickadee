// APIServer/Views/Pages/InstructorSlipDaysPage.swift
//
// GET /instructor/slip-days: the active course's slip-day policy, its facts
// card and the roster ledger, with the per-student adjust and refund actions
// (#1228).

import Elementary

struct InstructorSlipDaysPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    let enabled: Bool
    let daysPerStudent: Int
    let extensionHours: Int
    /// Whether release output waits out the claim window
    /// (`SlipDayPolicy.releaseRevealHold`).
    let releaseRevealHold: Bool
    /// Per-course instructor (or admin), non-archived: gates the policy form.
    let canEditSettings: Bool
    /// Non-archived: gates the adjust and refund buttons.
    let canManageLedger: Bool
    let settingsReadOnlyNote: String?
    let students: [SlipDayStudentRow]
    /// The facts card: "3 days", "24 hours", the release-hold wording, and the
    /// class-wide "11 of 93 spent" with its "8 students" note.
    let perStudentText: String
    let eachDayText: String
    let releaseHoldText: String
    let inUseText: String
    let inUseNote: String
    /// Whether the ledger has enough rows to earn a Filter box.
    let showFilter: Bool

    var body: some HTML {
        BaseLayout(title: "Slip days", page: page, flash: flash) {
            InstructorTabs(active: .slipDays)
            AvatarSprite(page: page)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its slip days." }
                }
            } else {
                div(.class("page-titlebar")) {
                    h2 {
                        "Slip days "
                        if enabled {
                            span(.class("tier tier-open")) { "On" }
                        } else {
                            span(.class("tier tier-closed")) { "Off" }
                        }
                    }
                    if canEditSettings {
                        a(
                            .class("btn action-btn"), .href("#slip-settings-panel"),
                            .data("add-target", value: "slip-settings-panel")
                        ) { "Edit settings" }
                    }
                }
                p(.class("section-intro")) {
                    "Students extend a deadline themselves from a fixed budget. A staff extension on an assignment always takes precedence."
                }
                if canEditSettings {
                    settingsPanel
                }
                factsCard
                ledger
            }
            PageStyle(
                """
                .slip-day-settings-check { display: flex; align-items: center; gap: .5rem; }
                .slip-day-settings-number { display: block; margin-top: .25rem; max-width: 8rem; }
                .slip-day-spend-refunded { text-decoration: line-through; }
                """
            )
            script(.src(page.asset("/list-filter.js"))) {}
        }
    }

    private var settingsPanel: some HTML {
        div(.class("add-panel card"), .id("slip-settings-panel")) {
            p(.class("section-note")) {
                "A slip day is a student-initiated deadline extension drawn from a fixed per-student budget, "
                    + "spent without staff involvement. After a deadline passes, an eligible student can claim "
                    + "one from the dashboard within one extension length of the deadline; days stack on a "
                    + "single assignment. Staff-granted extensions always take precedence: a student holding "
                    + "one cannot spend slip days on that assignment."
            }
            form(.method(.post), .action("/instructor/slip-days/settings"), .class("form-stack")) {
                CSRFField(token: page.csrfToken)
                // Each checkbox label is a flex row, so no space joins the
                // box and its text.
                label(.class("form-label slip-day-settings-check")) {
                    input(.type(.checkbox), .name("enabled"))
                        .attributes(.checked, when: enabled)
                    "Enable slip days for \(courseCode)"
                }
                label(.class("form-label")) {
                    "Days per student"
                    input(
                        .class("form-input slip-day-settings-number"), .type(.number), .name("daysPerStudent"),
                        .min(0), .max(100), .value(String(daysPerStudent)))
                }
                label(.class("form-label")) {
                    "Hours per slip day"
                    input(
                        .class("form-input slip-day-settings-number"), .type(.number), .name("extensionHours"),
                        .min(1), .max(336), .value(String(extensionHours)))
                    span(.class("field-note field-note--muted")) {
                        "Each day extends the original deadline by this many hours, and a claim must be made "
                            + "within that window."
                    }
                }
                label(.class("form-label")) {
                    span(.class("slip-day-settings-check")) {
                        input(.type(.checkbox), .name("releaseRevealHold"))
                            .attributes(.checked, when: releaseRevealHold)
                        "Hold release-tier output until slip-day claims lapse"
                    }
                    span(.class("field-note field-note--muted")) {
                        "Off shows release-tier output at each student’s deadline, "
                            + "even while they could still claim a slip day and act on it."
                    }
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Save settings" }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }

    private var factsCard: some HTML {
        section(.class("card page-section")) {
            dl(.class("detail-grid")) {
                dt { "Per student" }
                dd { strong { perStudentText } }
                dt { "Each day" }
                dd {
                    strong { eachDayText }
                    " "
                    span(.class("card-meta")) { "From the original deadline" }
                }
                dt { "Release-tier output" }
                dd { strong { releaseHoldText } }
                dt { "In use" }
                dd {
                    strong { inUseText }
                    " "
                    span(.class("card-meta")) { inUseNote }
                }
            }
            if let settingsReadOnlyNote {
                p(.class("section-note")) { settingsReadOnlyNote }
            }
        }
    }

    private var ledger: some HTML {
        section(.class("page-section")) {
            h2 { "Roster ledger" }
            if students.isEmpty {
                p(.class("empty")) { "No students enrolled." }
            } else {
                if showFilter {
                    div(.class("toolbar toolbar--end section-gap")) {
                        span(.class("filter-group")) {
                            label(.class("filter-label"), .for("slip-days-filter")) { "Filter" }
                            input(
                                .id("slip-days-filter"), .class("form-input filter-input"), .type(.search),
                                .placeholder("Filter by name or username…"),
                                .data("list-filter", value: "slip-days-ledger"),
                                .data("list-filter-empty", value: "No students match this filter."))
                        }
                    }
                }
                table(.class("results-table section-items section-items--manage"), .id("slip-days-ledger")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-status"))
                        col(.class("section-items-actions"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Person" }
                            th(.custom(name: "scope", value: "col"), .data("sort-key", value: "name")) { "Student" }
                            th(.custom(name: "scope", value: "col"), .data("sort-key", value: "left")) {
                                "Slip days left"
                            }
                            th(.custom(name: "scope", value: "col")) { "Actions" }
                        }
                    }
                    tbody {
                        for student in students {
                            SlipDayLedgerRow(page: page, student: student, canManageLedger: canManageLedger)
                        }
                    }
                }
            }
        }
    }
}

/// One student on the roster ledger: spends, pips, and the staff levers.
private struct SlipDayLedgerRow: HTML {
    let page: PageRequestContext
    let student: SlipDayStudentRow
    let canManageLedger: Bool

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) { Avatar(avatar: student.avatar) }
            td(.class("item-main")) {
                div(.class("item-title")) { student.displayName }
                div(.class("item-details")) {
                    code { student.username }
                    if !student.adjustmentText.isEmpty {
                        " · \(student.adjustmentText)"
                    }
                }
                for spend in student.spends {
                    div(.class("item-details")) {
                        span { "\(spend.assignmentTitle) → \(spend.extensionDueAtText)" }
                            .attributes(.class("slip-day-spend-refunded"), when: spend.isRefunded)
                        if spend.isRefunded {
                            " refunded \(spend.refundedAtText)"
                        }
                    }
                }
            }
            td(.class("item-status")) {
                span(.class("pips"), .ariaHidden) {
                    for pip in student.pips {
                        span(.class("pip"), .data("state", value: pip.state)) {}
                    }
                }
                div(.class("item-details")) { student.leftText }
            }
            td(.class("item-actions-td")) {
                if canManageLedger {
                    div(.class("assignment-actions-cell")) {
                        SlipDayAdjustForm(
                            page: page, userID: student.userID, delta: "-1", title: "Remove one slip day",
                            label: "Remove one slip day from \(student.username)", icon: "i-minus")
                        SlipDayAdjustForm(
                            page: page, userID: student.userID, delta: "1", title: "Grant one extra slip day",
                            label: "Grant \(student.username) one extra slip day", icon: "i-plus")
                        if !student.refundableSpends.isEmpty {
                            refundMenu
                        }
                    }
                }
            }
        }
    }

    private var refundMenu: some HTML {
        RowMenu(for: student.displayName) {
            for spend in student.refundableSpends {
                form(
                    .method(.post), .action("/instructor/slip-days/refund"),
                    .data(
                        "confirm",
                        value:
                            "Refund this slip day? The day is returned to the student and the deadline extension is recomputed (or removed)."
                    )
                ) {
                    CSRFField(token: page.csrfToken)
                    input(.type(.hidden), .name("spendID"), .value(spend.id))
                    button(.class("row-menu-item"), .type(.submit), .role("menuitem")) {
                        Icon("i-rewind")
                        "Refund \(spend.assignmentTitle) slip day"
                    }
                }
            }
        }
    }
}

/// One plus-or-minus-one budget adjustment button.
private struct SlipDayAdjustForm: HTML {
    let page: PageRequestContext
    let userID: String
    let delta: String
    let title: String
    let label: String
    let icon: String

    var body: some HTML {
        form(.method(.post), .action("/instructor/slip-days/adjust"), .class("inline-form")) {
            CSRFField(token: page.csrfToken)
            input(.type(.hidden), .name("userID"), .value(userID))
            input(.type(.hidden), .name("delta"), .value(delta))
            button(
                .class("btn action-btn action-btn-icon"), .type(.submit), .title(title), .ariaLabel(label)
            ) {
                Icon(icon)
            }
        }
    }
}
