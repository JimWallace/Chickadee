// APIServer/Views/Pages/InstructorBrightspacePage.swift
//
// GET /instructor/brightspace: the instructor LEARN tab. The facts card (who
// the course pushes as, its org unit, the last sync), the per-instructor
// connection, the assignment-to-grade-item mapping and the roster readiness
// panel. `BrightSpacePagePresenter` builds the view model. The connection test
// and the grade-item pickers are wired by Public/instructor-brightspace.js.

import Elementary

struct InstructorBrightspacePage: HTML {
    let page: PageRequestContext
    let model: InstructorBrightspaceContext

    var body: some HTML {
        BaseLayout(
            title: "LEARN", page: page,
            flash: FlashMessages(success: model.flashSuccess, error: model.flashError)
        ) {
            InstructorTabs(active: .brightspace)
            AvatarSprite(page: page)
            if model.hasActiveCourse {
                titlebar
                if model.usesLTIGrades {
                    FlashBanner(.neutral) {
                        "Grades for this course go to the LMS through the LTI grade service, not the Valence sync."
                    }
                }
            }
            // Nothing course-scoped renders without app credentials.
            if model.brightspaceSyncEnabled, !model.hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its LEARN grade sync." }
                }
            } else if model.brightspaceSyncEnabled {
                if !model.syncHealthy {
                    FlashBanner(.warning) {
                        "Grade sync is paused: the LEARN account this course pushes as is disconnected. "
                        if model.usesServiceAccount {
                            "Ask a Chickadee admin."
                        } else {
                            "It resumes when they reconnect, or a connected co-instructor takes over below."
                        }
                    }
                }
                InstructorBrightspaceFacts(page: page, model: model)
                if !model.usesServiceAccount {
                    InstructorBrightspaceConnection(page: page, model: model)
                }
                InstructorBrightspaceMapping(page: page, model: model)
                InstructorBrightspaceRoster(page: page, model: model)
            }
            PageStyle(
                """
                .bs-grade-form { display: flex; gap: .4rem; align-items: center; margin: 0; }
                .bs-grade-input { font-size: var(--text-base); }
                .bs-conn-line { margin: 0 0 .45rem; }
                .bs-test-result { margin: 0; padding: 0 1.25rem 1rem; font-size: var(--text-base); }
                """
            )
            script(.src(page.asset("/instructor-brightspace.js"))) {}
        }
    }

    private var titlebar: some HTML {
        div(.class("page-titlebar")) {
            h2 {
                "LEARN "
                if model.brightspaceSyncEnabled {
                    if model.syncHealthy {
                        span(.class("tier tier-open")) { "Connected" }
                    } else {
                        span(.class("tier tier-danger")) { "Paused" }
                    }
                }
            }
            div(.class("assignment-actions-cell")) {
                if model.showLTIGradesLink {
                    a(.class("btn action-btn"), .href("/instructor/lti-grades")) { "LMS grades" }
                }
                if model.canSyncNow {
                    form(.method(.post), .action("/instructor/brightspace/sync-now"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        button(
                            .class("btn btn-primary"), .type(.submit),
                            .title("Re-queue any failed grades and push every pending grade to LEARN now")
                        ) { "Sync now" }
                    }
                }
            }
        }
    }
}

/// The facts card: who the course pushes as, its org unit and the last sync.
private struct InstructorBrightspaceFacts: HTML {
    let page: PageRequestContext
    let model: InstructorBrightspaceContext

    var body: some HTML {
        section(.class("card page-section")) {
            div(.class("facts-actions")) {
                button(
                    .class("btn action-btn"), .type(.button), .id("bs-test-connection"),
                    .title("Verify this course's grade-push credentials against D2L")
                ) { "Test connection" }
                if model.canBindOrgUnit {
                    orgUnitPopup
                }
            }
            dl(.class("detail-grid")) {
                dt { "Pushes as" }
                dd {
                    strong { model.pushesAsText }
                    if !model.pushesAsNote.isEmpty {
                        " "
                        span(.class("card-meta")) { model.pushesAsNote }
                    }
                }
                dt { "Org unit" }
                dd {
                    if model.courseLinked {
                        strong { model.orgUnitDisplay ?? "" }
                    } else {
                        span(.class("text-muted")) { "Not linked" }
                    }
                }
                dt { "Last sync" }
                dd {
                    if let iso = model.lastSyncISO {
                        strong(.class("js-relative-time"), .data("iso", value: iso)) { model.lastSyncText }
                    } else {
                        strong { model.lastSyncText }
                    }
                    " "
                    span(.class("card-meta")) { "Automatic" }
                }
            }
            div(.class("bs-test-result"), .id("bs-test-result"), .hidden) {}
        }
    }

    private var orgUnitPopup: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "Change org unit "
                Icon("i-chevron-down")
            }
            div(
                .class("add-section-popup card suite-section-popup"), .role("dialog"),
                .ariaLabel("Change org unit")
            ) {
                form(.method(.post), .action("/instructor/brightspace/bind-org-unit"), .class("form popup-form")) {
                    CSRFField(token: page.csrfToken)
                    label(.class("form-label"), .for("bs-org-unit-input")) {
                        "LEARN org unit ID"
                        input(
                            .class("form-input"), .type(.text), .id("bs-org-unit-input"), .name("orgUnitID"),
                            .value(model.orgUnitFieldValue), .autocomplete("off"), .placeholder("e.g. 1106038"))
                        span(.class("field-note field-note--muted")) { "Leave blank to unlink the course." }
                    }
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Save org unit" }
                    }
                }
            }
        }
    }
}

/// The per-instructor LEARN identity (#1114). Shown only when the deployment
/// has no service account; with one, grades always push through it.
private struct InstructorBrightspaceConnection: HTML {
    let page: PageRequestContext
    let model: InstructorBrightspaceContext

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "Connection" }
            if model.account.connected {
                p(.class("bs-conn-line")) {
                    "Your LEARN account: "
                    strong { model.account.identity ?? "" }
                    model.account.since ?? ""
                }
            } else {
                p(.class("bs-conn-line")) { "Your LEARN account is not connected." }
            }
            if let name = model.syncIdentity.name {
                p(.class("bs-conn-line")) {
                    "This course pushes grades as "
                    strong { name }
                    "."
                }
            }
            if model.showConnectForm {
                connectForm
            }
            if model.showIdentityActions {
                div(.class("toolbar")) {
                    if model.showUseMyIdentity {
                        form(
                            .method(.post), .action("/instructor/brightspace/use-my-identity"), .class("inline-form")
                        ) {
                            CSRFField(token: page.csrfToken)
                            button(
                                .class("btn action-btn"), .type(.submit),
                                .title("Push this course's grades as your LEARN account")
                            ) { "Use my account for this course" }
                        }
                    }
                    form(
                        .method(.post), .action("/instructor/brightspace/disconnect"), .class("inline-form"),
                        .data(
                            "confirm",
                            value:
                                "Disconnect your LEARN account? Courses that push grades as you will pause until someone reconnects."
                        )
                    ) {
                        CSRFField(token: page.csrfToken)
                        button(.class("btn action-btn action-danger"), .type(.submit)) { "Disconnect my account" }
                    }
                    a(.class("btn action-btn"), .href("/instructor/grades.csv")) { "Export Grades CSV" }
                }
            } else {
                div(.class("toolbar")) {
                    a(.class("btn action-btn"), .href("/instructor/grades.csv")) { "Export Grades CSV" }
                }
            }
        }
    }

    @HTMLBuilder private var connectForm: some HTML {
        // The label text and the input sit in a flex row, so no space joins them.
        form(.method(.post), .action("/instructor/brightspace/connect"), .class("toolbar")) {
            CSRFField(token: page.csrfToken)
            label(.class("field-inline")) {
                "Valence User ID"
                input(
                    .class("form-input input-compact"), .type(.text), .id("bs-valence-user-id"), .name("userID"),
                    .autocomplete("off"), .required, .custom(name: "aria-describedby", value: "bs-connect-note"))
            }
            label(.class("field-inline")) {
                "Valence User Key"
                input(
                    .class("form-input input-compact"), .type(.password), .id("bs-valence-user-key"),
                    .name("userKey"), .autocomplete("off"), .required,
                    .custom(name: "aria-describedby", value: "bs-connect-note"))
            }
            button(.class("btn btn-primary"), .type(.submit)) { "Connect my LEARN account" }
        }
        p(.class("field-note"), .id("bs-connect-note")) {
            "Follow the "
            a(
                .href(
                    "https://github.com/JimWallace/Chickadee/blob/main/docs/brightspace-setup.md#per-instructor-identity"
                ),
                .target(.blank), .rel("noopener noreferrer")
            ) {
                "LEARN setup guide "
                Icon("i-external")
                span(.class("visually-hidden")) { "(opens in a new tab)" }
            }
            " to get a Valence User ID and User Key for your own account."
        }
    }
}

/// The assignment-to-grade-item mapping table.
private struct InstructorBrightspaceMapping: HTML {
    let page: PageRequestContext
    let model: InstructorBrightspaceContext

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Grade-item mapping" }
                if !model.courseIsArchived {
                    form(.method(.post), .action("/instructor/brightspace/auto-map"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        button(
                            .class("btn action-btn"), .type(.submit),
                            .title("Map unmapped assignments to grade items with a matching name")
                        ) { "Auto-map by name" }
                    }
                }
            }
            if model.assignmentRows.isEmpty {
                p(.class("empty")) { "No assignments in this course yet." }
            } else {
                datalist(.id("bs-grade-objects"), .data("do-not-sync-token", value: model.doNotSyncToken)) {}
                table(.class("results-table section-items section-items--manage")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-combo"))
                        col(.class("section-items-grade col-hide-phone"))
                        col(.class("section-items-count"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Type" }
                            th(.custom(name: "scope", value: "col")) { "Assignment" }
                            th(.custom(name: "scope", value: "col")) { "LEARN assessment" }
                            th(.custom(name: "scope", value: "col"), .class("col-hide-phone")) { "Students synced" }
                            th(.custom(name: "scope", value: "col")) { "Actions" }
                        }
                    }
                    tbody {
                        for row in model.assignmentRows {
                            InstructorBrightspaceMappingRow(
                                page: page, row: row, courseIsArchived: model.courseIsArchived)
                        }
                    }
                }
            }
        }
    }
}

/// One assignment's grade-item picker, sync rollup and re-push action.
private struct InstructorBrightspaceMappingRow: HTML {
    let page: PageRequestContext
    let row: BrightspaceAssignmentRow
    let courseIsArchived: Bool

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-calendar-check") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { row.title }
                div(.class(row.hasSyncError ? "item-details chip-err" : "item-details")) { row.syncDetailText }
            }
            td(.class("item-status")) {
                form(
                    .method(.post), .action("/instructor/\(row.assignmentID)/brightspace"), .class("bs-grade-form"),
                    .data("assignment-id", value: row.assignmentID)
                ) {
                    CSRFField(token: page.csrfToken)
                    input(.type(.hidden), .name("returnTo"), .value("brightspace"))
                    input(.type(.hidden), .name("gradeObjectID"), .class("js-bs-grade-id-hidden"))
                    label(.class("visually-hidden"), .for("bs-go-\(row.assignmentID)")) {
                        "LEARN Assessment for \(row.title)"
                    }
                    span(.class("state-select"), .data("state", value: row.isMapped ? "mapped" : "unmapped")) {
                        input(
                            .class("form-input bs-grade-input"), .type(.text), .id("bs-go-\(row.assignmentID)"),
                            .list("bs-grade-objects"), .value(row.gradeFieldValue),
                            .placeholder("Search assessments…"), .data("raw-id", value: row.gradeFieldValue),
                            .autocomplete("off"))
                    }
                    button(.class("btn action-btn"), .type(.submit)) { "Save" }
                }
            }
            td(.class("item-grade col-hide-phone")) {
                if row.hasSyncActivity {
                    div {
                        strong(.title("Synced to LEARN")) { String(row.syncedCount) }
                        " synced"
                    }
                    div(.class(row.erroredCount > 0 ? "item-details chip-err" : "item-details")) {
                        span(.title("Failed to push")) { String(row.erroredCount) }
                        " failed"
                    }
                } else {
                    span(.class("empty")) { "—" }
                }
            }
            td(.class("item-actions-td")) {
                if !courseIsArchived {
                    div(.class("assignment-actions-cell")) {
                        form(
                            .method(.post), .action("/instructor/\(row.assignmentID)/brightspace/push-all"),
                            .class("inline-form"),
                            .data("confirm", value: "Re-push every student's best grade for \(row.title) to LEARN?")
                        ) {
                            CSRFField(token: page.csrfToken)
                            button(
                                .class("btn action-btn action-btn-icon"), .type(.submit),
                                .title("Re-push all grades for \(row.title)"),
                                .ariaLabel("Re-push all grades for \(row.title)")
                            ) {
                                Icon("i-push-down")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The roster readiness panel: students a grade cannot reach in LEARN.
private struct InstructorBrightspaceRoster: HTML {
    let page: PageRequestContext
    let model: InstructorBrightspaceContext

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Class Roster" }
                if model.canReconcile {
                    form(.method(.post), .action("/instructor/brightspace/reconcile-now"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        button(
                            .class("btn action-btn"), .type(.submit),
                            .title("Re-check the roster against the LEARN classlist now")
                        ) { "Reconcile now" }
                    }
                }
            }
            if !model.courseLinked && model.canBindOrgUnit {
                p(.class("section-note")) {
                    "Link this course to its LEARN org unit (Change org unit, above) to check "
                        + "whether each student's grade can be delivered to the LEARN gradebook."
                }
            }
            if model.courseLinked {
                if !model.unreachableStudents.isEmpty {
                    p(.class("section-note")) { model.readinessSummary }
                    table(.class("results-table section-items section-items--manage")) {
                        colgroup {
                            col(.class("section-items-tile"))
                            col()
                            col(.class("section-items-actions"))
                        }
                        thead(.class("visually-hidden")) {
                            tr {
                                th(.custom(name: "scope", value: "col")) { "Person" }
                                th(.custom(name: "scope", value: "col")) { "Student" }
                                th(.custom(name: "scope", value: "col")) { "Actions" }
                            }
                        }
                        tbody {
                            for student in model.unreachableStudents {
                                InstructorBrightspaceRosterRow(page: page, student: student)
                            }
                        }
                    }
                } else {
                    p(.class("empty")) { "All students can receive grades in LEARN." }
                }
            }
        }
    }
}

/// One student a grade cannot reach, with the match and remove actions.
private struct InstructorBrightspaceRosterRow: HTML {
    let page: PageRequestContext
    let student: BrightspaceReadinessRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                if let avatar = student.avatar {
                    Avatar(avatar: avatar)
                }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { student.displayName }
                div(.class("item-details")) {
                    code { student.username }
                    " · "
                    span(.class("chip-err"), .title(student.detail)) { "Couldn't match to LEARN" }
                }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    a(
                        .class("btn action-btn action-btn-icon"),
                        .href("/instructor/students?highlight=\(student.userID)"),
                        .title("Match this student's LEARN ID"), .ariaLabel("Match \(student.displayName)'s LEARN ID")
                    ) {
                        Icon("i-link")
                    }
                    RowMenu(for: student.displayName) {
                        form(
                            .method(.post), .action(student.unenrollURL),
                            .data("confirm", value: "Remove \(student.displayName) from this course?")
                        ) {
                            CSRFField(token: page.csrfToken)
                            button(
                                .class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")
                            ) {
                                Icon("i-trash")
                                "Remove from course"
                            }
                        }
                    }
                }
            }
        }
    }
}
