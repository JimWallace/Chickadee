// APIServer/Views/Pages/InstructorStudentsPage.swift
//
// GET /instructor/students: the Students tab. The course staff above, then the
// enrolled students and pending pre-enrolments, which `table-poll.js` keeps
// current from `/instructor/students-data?fragment=rows` (`StudentRows`).

import Elementary

struct InstructorStudentsPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    /// The active course's id, or nil when the viewer has none: the roster
    /// controls need a course to post to.
    let activeCourseID: String?
    /// Student-role rows plus pending pre-enrolments: the polled table.
    let students: [EnrolledStudentRow]
    /// Instructor and TA rows: a small static list above the students.
    let staffRows: [EnrolledStudentRow]
    /// The title bar's "31 enrolled · 2 pending".
    let activeStudentCount: Int
    let pendingCount: Int
    /// Whether the students list has enough rows to earn a Filter box
    /// (`ListFilterPolicy`).
    let showStudentFilter: Bool
    let courseEnrollmentMode: String
    /// An archived course, or a TA: every mutating control is hidden.
    let rosterReadOnly: Bool
    /// The "Add staff member" panel's fields.
    let staffForm: StaffFieldsContext

    var body: some HTML {
        BaseLayout(title: "Students", page: page, flash: flash) {
            InstructorTabs(active: .students)
            AvatarSprite(page: page)
            titlebar
            if let activeCourseID, !rosterReadOnly {
                div(.class("add-panel card"), .id("add-staff-panel")) {
                    form(.method(.post), .action("/courses/\(activeCourseID)/staff"), .class("form-stack")) {
                        CSRFField(token: page.csrfToken)
                        StaffFields(form: staffForm)
                        div(.class("toolbar")) {
                            button(.class("btn btn-primary"), .type(.submit)) { "Add" }
                            button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                        }
                    }
                }
                .attributes(.class("is-open"), when: staffForm.error != nil)
            }
            if !staffRows.isEmpty {
                h3(.class("assignment-section-heading")) { "Course staff" }
                staffTable
                h3(.class("assignment-section-heading")) { "Students" }
            }
            if showStudentFilter {
                div(.class("toolbar toolbar--end section-gap")) {
                    span(.class("filter-group")) {
                        label(.class("filter-label"), .for("enrolled-filter")) { "Filter" }
                        input(
                            .id("enrolled-filter"), .class("form-input filter-input"), .type(.search),
                            .placeholder("Filter by name or username…"),
                            .data("list-filter", value: "enrolled-students-table"),
                            .data("list-filter-empty", value: "No students match this filter."))
                    }
                }
            }
            studentsTable
            p(.class("empty"), .id("no-students-msg")) { "No students enrolled yet." }
                .attributes(.hidden, when: !students.isEmpty)
            PageStyle(
                """
                /* The global .page-titlebar puts the title left and actions right; the roster
                   adds only that the cluster wraps. */
                .students-titlebar { flex-wrap: wrap; gap: .75rem; }
                """
            )
            script(.src(page.asset("/list-filter.js"))) {}
            script(.src(page.asset("/sortable-table.js"))) {}
            script(.src(page.asset("/table-poll.js"))) {}
            // Row-click navigation, the roster counts and the empty state are
            // wired by Public/instructor-students.js.
            script(.src(page.asset("/instructor-students.js"))) {}
        }
    }

    private var titlebar: some HTML {
        div(.class("page-titlebar students-titlebar")) {
            h2 {
                "Students "
                span(.class("text-muted")) {
                    span(.id("enrolled-count")) { "\(activeStudentCount)" }
                    " enrolled · "
                    span(.id("pending-count")) { "\(pendingCount)" }
                    " pending"
                }
            }
            if let activeCourseID, !rosterReadOnly {
                form(
                    .method(.post), .action("/courses/\(activeCourseID)/enrollment-mode"), .class("form-flush")
                ) {
                    CSRFField(token: page.csrfToken)
                    label(.class("visually-hidden"), .for("enrollment-mode")) { "Enrolment mode" }
                    span(.class("state-select"), .data("state", value: courseEnrollmentMode)) {
                        select(
                            .id("enrollment-mode"), .name("enrollmentMode"), .class("form-input"),
                            .dataFlag("ck-submit-on-change")
                        ) {
                            option(.value("open")) { "Open enrolment" }
                                .attributes(.selected, when: courseEnrollmentMode == "open")
                            option(.value("auto")) { "Auto enrolment" }
                                .attributes(.selected, when: courseEnrollmentMode == "auto")
                            option(.value("closed")) { "Closed enrolment" }
                                .attributes(.selected, when: courseEnrollmentMode == "closed")
                        }
                    }
                }
                addMenu
            }
        }
    }

    private var addMenu: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "+ Add "
                Icon("i-chevron-down")
            }
            div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                a(.class("row-menu-item"), .href("/instructor/enroll-csv"), .role("menuitem")) {
                    span(.class("item-tile"), .data("kind", value: "document")) { Icon("i-upload") }
                    span {
                        "Enrol from CSV"
                        br()
                        span(.class("card-meta")) { "Username list; unknown users wait as pending" }
                    }
                }
                a(
                    .class("row-menu-item"), .href("#add-staff-panel"), .role("menuitem"),
                    .data("add-target", value: "add-staff-panel")
                ) {
                    span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-key") }
                    span {
                        "Add staff member"
                        br()
                        span(.class("card-meta")) { "A co-instructor or TA, by username or email" }
                    }
                }
            }
        }
    }

    private var staffTable: some HTML {
        table(
            .class("results-table section-items section-items--manage"), .id("course-staff-table")
        ) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                col(.class("section-items-actions"))
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Person" }
                    th(.custom(name: "scope", value: "col")) { "Name" }
                    th(.custom(name: "scope", value: "col")) { "Role" }
                    th(.custom(name: "scope", value: "col")) { "Actions" }
                }
            }
            tbody {
                for staff in staffRows {
                    StaffRow(staff: staff, rosterReadOnly: rosterReadOnly, csrfToken: page.csrfToken)
                }
            }
        }
    }

    private var studentsTable: some HTML {
        table(
            .class("results-table section-items section-items--manage sortable-table"),
            .id("enrolled-students-table"),
            .data("sort-initial", value: "last-seen:desc"), .data("sort-tiebreak", value: "name"),
            .data("poll-url", value: "/instructor/students-data?fragment=rows"),
            .data("poll-interval", value: "5000")
        ) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                col(.class("section-items-seen col-hide-phone"))
                col(.class("section-items-actions"))
            }
            thead {
                tr {
                    th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Person" } }
                    SortHeader(key: "name", type: "text", label: "Name")
                    SortHeader(key: "role", type: "text", label: "Role")
                    SortHeader(key: "last-seen", type: "date", label: "Last seen", hideOnPhone: true)
                    th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Actions" } }
                }
            }
            tbody {
                StudentRows(students: students, rosterReadOnly: rosterReadOnly, csrfToken: page.csrfToken)
            }
        }
    }
}

/// One instructor or TA: bird, name, role, and the remove action.
private struct StaffRow: HTML {
    let staff: EnrolledStudentRow
    let rosterReadOnly: Bool
    let csrfToken: String

    var body: some HTML {
        tr(.data("student-id", value: staff.id)) {
            td(.class("item-tile-cell")) {
                if let avatar = staff.avatar { Avatar(avatar: avatar) }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { staff.displayName }
                div(.class("item-details")) { code { staff.username } }
            }
            td(.class("item-status")) {
                if rosterReadOnly {
                    staff.role
                } else if let roleSelect = staff.roleSelect {
                    RoleSelect(cell: roleSelect, csrfToken: csrfToken)
                }
            }
            td(.class("item-actions-td")) {
                if !rosterReadOnly {
                    div(.class("assignment-actions-cell")) {
                        RowMenu(for: staff.displayName) {
                            form(
                                .method(.post), .action(staff.unenrollURL),
                                .data("confirm", value: "Remove @\(staff.username) from this course?")
                            ) {
                                CSRFField(token: csrfToken)
                                button(
                                    .class("row-menu-item row-menu-item--danger"), .type(.submit),
                                    .role("menuitem")
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
}
