// APIServer/Views/Pages/AdminCoursePage.swift
//
// GET /admin/courses/new and GET /admin/courses/:courseID: the new-course form,
// or one course with its settings, clone and staff forms, its facts, its
// assignments and its enrolled people.

import Elementary

struct AdminCoursePage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let course: AdminCourseRow
    let enrolledUsers: [AdminCourseEnrolledUserRow]
    let assignments: [AdminCourseAssignmentRow]
    /// True on the new-course form, which shows only the form and the (empty)
    /// assignments section.
    let isNew: Bool
    /// The new-course form, or a course's settings form.
    let courseForm: CourseFieldsContext
    /// The clone form; nil on the new-course page.
    var cloneForm: CourseFieldsContext?
    /// True when a person with no account can be named as staff.
    var placeholderAllowed = false
    /// The staff form; nil on the new-course page.
    var staffForm: StaffFieldsContext?

    var body: some HTML {
        BaseLayout(title: isNew ? "New Course — Admin" : "\(course.code) — Admin", page: page, flash: flash) {
            if isNew {
                newCourse
            } else {
                AvatarSprite(page: page)
                AdminCourseHeader(course: course, csrfToken: page.csrfToken)
                AdminCourseForms(
                    course: course, courseForm: courseForm, cloneForm: cloneForm, csrfToken: page.csrfToken)
                AdminCourseFacts(course: course)
            }
            AdminCourseAssignments(assignments: assignments)
            if !isNew {
                AdminCourseRoster(
                    course: course, enrolledUsers: enrolledUsers, staffForm: staffForm, csrfToken: page.csrfToken)
            }
        }
    }

    @HTMLBuilder private var newCourse: some HTML {
        div(.class("page-titlebar")) {
            h1 { "New Course" }
            a(.href("/admin"), .class("btn")) { "Cancel" }
        }
        section(.class("page-section")) {
            h2 { "Course details" }
            form(.method(.post), .action("/admin/courses"), .class("form-stack")) {
                CSRFField(token: page.csrfToken)
                CourseFields(form: courseForm)
                div(.class("field-stack field-stack--narrow")) {
                    label(.for("new-course-instructor")) { "Instructor (optional)" }
                    input(
                        .id("new-course-instructor"), .class("form-input"), .type(.text), .name("instructor"),
                        .autocomplete("off"), .placeholder("e.g. jdoe"),
                        .custom(name: "aria-describedby", value: "new-course-instructor-note"))
                    p(.class("field-note"), .id("new-course-instructor-note")) {
                        placeholderAllowed ? "Need not have signed in yet." : "Must already have an account."
                    }
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Create course" }
                }
            }
        }
    }
}

/// The course's title bar: its name and the settings, clone and more-actions
/// controls.
private struct AdminCourseHeader: HTML {
    let course: AdminCourseRow
    let csrfToken: String

    var body: some HTML {
        div(.class("page-titlebar")) {
            h1 {
                course.code
                if let termLabel = course.termLabel { " \(termLabel)" }
                " — \(course.name)"
            }
            div(.class("toolbar")) {
                a(
                    .class("btn action-btn"), .href("#course-settings-panel"),
                    .data("add-target", value: "course-settings-panel")
                ) { "Edit settings" }
                a(.class("btn action-btn"), .href("#clone-course"), .data("add-target", value: "clone-course")) {
                    "Clone course"
                }
                details(.class("add-section-details popup-anchor")) {
                    summary(
                        .class("btn action-btn action-btn-icon summary-btn"), .title("More actions"),
                        .ariaLabel("More actions for \(course.code)")
                    ) {
                        Icon("i-more")
                    }
                    div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                        a(.class("row-menu-item"), .href("/admin/courses/\(course.id)/export"), .role("menuitem")) {
                            Icon("i-download")
                            "Export course bundle"
                        }
                        aiFeedbackForm
                        archiveForm
                    }
                }
            }
        }
    }

    @HTMLBuilder private var aiFeedbackForm: some HTML {
        if course.aiFeedbackEnabled {
            form(
                .method(.post), .action("/admin/courses/\(course.id)/ai-feedback"),
                .data(
                    "confirm",
                    value:
                        "Turn off AI-assisted feedback for \(course.code)? No agent can read answers or add drafts in any of its assignments. Feedback already released stays visible."
                )
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item"), .type(.submit), .role("menuitem")) { "Turn off AI-assisted feedback" }
            }
        } else {
            form(
                .method(.post), .action("/admin/courses/\(course.id)/ai-feedback"),
                .data(
                    "confirm",
                    value:
                        "Turn on AI-assisted feedback for \(course.code)? Do this only after the course has its AI-use approval (see docs/ai-assisted-feedback.md). Instructors can then let their own AI agent read students' written answers, without names, in the assignments they opt in."
                )
            ) {
                CSRFField(token: csrfToken)
                input(.type(.hidden), .name("enabled"), .value("on"))
                button(.class("row-menu-item"), .type(.submit), .role("menuitem")) { "Turn on AI-assisted feedback" }
            }
        }
    }

    @HTMLBuilder private var archiveForm: some HTML {
        if course.isArchived {
            form(
                .method(.post), .action("/admin/courses/\(course.id)/archive"),
                .data(
                    "confirm",
                    value:
                        "Unarchive \(course.code)? \(course.enrollmentCount) students regain access immediately, and the retention clock stops."
                )
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item"), .type(.submit), .role("menuitem")) {
                    Icon("i-archive")
                    "Unarchive course"
                }
            }
        } else {
            form(
                .method(.post), .action("/admin/courses/\(course.id)/archive"),
                .data(
                    "confirm",
                    value:
                        "Archive \(course.code)? \(course.enrollmentCount) students lose access immediately. Submissions, grades and audit records are kept, and Unarchive on this page puts it back."
                )
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    Icon("i-archive")
                    "Archive course"
                }
            }
        }
    }
}

/// The settings and clone panels the title bar's buttons open.
private struct AdminCourseForms: HTML {
    let course: AdminCourseRow
    let courseForm: CourseFieldsContext
    let cloneForm: CourseFieldsContext?
    let csrfToken: String

    var body: some HTML {
        div(.class("add-panel card"), .id("course-settings-panel")) {
            form(.method(.post), .action("/admin/courses/\(course.id)/edit"), .class("form-stack")) {
                CSRFField(token: csrfToken)
                CourseFields(form: courseForm)
                if course.brightspaceSyncEnabled {
                    div(.class("field-stack field-stack--narrow")) {
                        label(.for("course-settings-org-unit")) { "LEARN org unit ID" }
                        input(
                            .id("course-settings-org-unit"), .class("form-input"), .type(.text),
                            .name("brightspaceOrgUnitID"), .value(course.brightspaceOrgUnitID ?? ""),
                            .placeholder("e.g. 123456"),
                            .custom(name: "aria-describedby", value: "course-settings-org-unit-note"))
                        p(.class("field-note"), .id("course-settings-org-unit-note")) {
                            "Checked against D2L when you save."
                        }
                    }
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Save settings" }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
        .attributes(.class("is-open"), when: courseForm.error != nil)
        if let cloneForm {
            div(.class("add-panel card"), .id("clone-course")) {
                form(.method(.post), .action("/admin/courses/\(course.id)/clone"), .class("form-stack")) {
                    CSRFField(token: csrfToken)
                    p(.class("section-note")) {
                        "Students, submissions and grades stay here; copied assignments start closed, with no "
                        "dates and the solution reveal off."
                    }
                    CourseFields(form: cloneForm)
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Clone course" }
                        button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                    }
                }
            }
            .attributes(.class("is-open"), when: cloneForm.error != nil)
        }
    }
}

/// The facts card: status, term, submissions, the AI feedback gate and the
/// LEARN org unit.
private struct AdminCourseFacts: HTML {
    let course: AdminCourseRow

    var body: some HTML {
        div(.class("card section-gap")) {
            dl(.class("detail-grid")) {
                dt { "Status" }
                dd {
                    if course.isArchived {
                        span(.class("tier tier-closed")) { "Archived" }
                    } else {
                        span(.class("tier tier-open")) { "Active" }
                    }
                }
                dt { "Term" }
                dd {
                    if let termLabel = course.termLabel {
                        termLabel
                    } else {
                        span(.class("text-muted")) { "None recorded" }
                    }
                }
                dt { "Submissions" }
                dd { "\(course.submissionCount)" }
                dt { "AI-assisted feedback" }
                dd {
                    if course.aiFeedbackEnabled {
                        span(.class("tier tier-open")) { "On" }
                    } else {
                        span(.class("tier tier-closed")) { "Off" }
                    }
                }
                if course.brightspaceSyncEnabled {
                    dt { "LEARN org unit" }
                    dd { orgUnit }
                }
            }
        }
    }

    @HTMLBuilder private var orgUnit: some HTML {
        if let orgUnitID = course.brightspaceOrgUnitID {
            if let orgUnitName = course.brightspaceOrgUnitName {
                "\(orgUnitName) "
                span(.class("card-meta")) {
                    "ID "
                    code { orgUnitID }
                }
                " "
                span(.class("tier tier-open")) { "Verified" }
            } else {
                code { orgUnitID }
                " "
                span(.class("tier tier-danger")) { "Not verified" }
                " "
                span(.class("card-meta")) { "Save the settings again to retry." }
            }
        } else {
            span(.class("text-muted")) { "Not set" }
        }
    }
}

/// The course's assignments, by due date.
private struct AdminCourseAssignments: HTML {
    let assignments: [AdminCourseAssignmentRow]

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "Assignments (\(assignments.count))" }
            if assignments.isEmpty {
                p(.class("empty")) { "No assignments for this course." }
            } else {
                table(.class("results-table section-items")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-status"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Kind" }
                            th(.custom(name: "scope", value: "col")) { "Assignment" }
                            th(.custom(name: "scope", value: "col")) { "Status" }
                        }
                    }
                    tbody {
                        for assignment in assignments {
                            AdminCourseAssignmentItem(assignment: assignment)
                        }
                    }
                }
            }
        }
    }
}

private struct AdminCourseAssignmentItem: HTML {
    let assignment: AdminCourseAssignmentRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-calendar-check") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    a(.href("/instructor/\(assignment.id)/submissions")) { assignment.title }
                }
                div(.class("item-details")) {
                    if let dueAt = assignment.dueAt { "Due \(dueAt)" } else { "No due date" }
                }
            }
            td(.class("item-status")) {
                switch assignment.visibility {
                case "open": span(.class("tier tier-open")) { "Open" }
                case "preview": span(.class("tier tier-preview")) { "Preview" }
                default: span(.class("tier tier-closed")) { "Closed" }
                }
            }
        }
    }
}

/// The enrolled people: the enrolment controls, the staff form and one row
/// each.
private struct AdminCourseRoster: HTML {
    let course: AdminCourseRow
    let enrolledUsers: [AdminCourseEnrolledUserRow]
    let staffForm: StaffFieldsContext?
    let csrfToken: String

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Enrolled students (\(course.enrollmentCount))" }
                div(.class("toolbar")) {
                    enrollmentModeForm
                    if !course.isArchived {
                        a(
                            .class("btn action-btn"), .href("#add-staff-panel"),
                            .data("add-target", value: "add-staff-panel")
                        ) {
                            "Add staff"
                        }
                        form(
                            .method(.post), .action("/admin/courses/\(course.id)/enroll-csv"),
                            .enctype(.multipartFormData), .class("form-flush")
                        ) {
                            CSRFField(token: csrfToken)
                            label(.class("btn action-btn")) {
                                "Enrol from CSV "
                                // The one inline style the UI rules allow: a
                                // JS-free hidden file input the label opens.
                                input(
                                    .type(.file), .name("file"), .accept(".csv,.txt"), .required,
                                    .custom(name: "style", value: "display:none"), .dataFlag("ck-submit-on-change"))
                            }
                        }
                    }
                }
            }
            if !course.isArchived, let staffForm {
                div(.class("add-panel card"), .id("add-staff-panel")) {
                    form(.method(.post), .action("/admin/courses/\(course.id)/staff"), .class("form-stack")) {
                        CSRFField(token: csrfToken)
                        StaffFields(form: staffForm)
                        div(.class("toolbar")) {
                            button(.class("btn btn-primary"), .type(.submit)) { "Add" }
                            button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                        }
                    }
                }
                .attributes(.class("is-open"), when: staffForm.error != nil)
            }
            if enrolledUsers.isEmpty {
                p(.class("empty")) { "No students enrolled yet." }
            } else {
                table(.class("results-table section-items section-items--manage")) {
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
                        for user in enrolledUsers {
                            AdminCourseUserRow(course: course, user: user, csrfToken: csrfToken)
                        }
                    }
                }
            }
        }
    }

    private var enrollmentModeForm: some HTML {
        form(.method(.post), .action("/admin/courses/\(course.id)/enrollment-mode"), .class("form-flush")) {
            CSRFField(token: csrfToken)
            label(.class("visually-hidden"), .for("enrollment-mode")) { "Enrolment mode" }
            span(.class("state-select"), .data("state", value: course.enrollmentMode)) {
                select(
                    .id("enrollment-mode"), .name("enrollmentMode"), .class("form-input"),
                    .dataFlag("ck-submit-on-change")
                ) {
                    option(.value("open")) { "Open enrolment" }
                        .attributes(.selected, when: course.enrollmentMode == "open")
                    option(.value("auto")) { "Auto enrolment" }
                        .attributes(.selected, when: course.enrollmentMode == "auto")
                    option(.value("closed")) { "Closed enrolment" }
                        .attributes(.selected, when: course.enrollmentMode == "closed")
                }
            }
        }
    }
}

/// One enrolled person: bird, name, role select and the row actions.
private struct AdminCourseUserRow: HTML {
    let course: AdminCourseRow
    let user: AdminCourseEnrolledUserRow
    let csrfToken: String

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                if user.hasAvatar, let avatar = user.avatar { Avatar(avatar: avatar) }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { user.displayName ?? user.username }
                div(.class("item-details")) { code { user.username } }
            }
            td(.class("item-status")) {
                if course.isArchived {
                    user.role
                } else if let roleSelect = user.roleSelect {
                    RoleSelect(cell: roleSelect, csrfToken: csrfToken)
                }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    a(
                        .href("/admin/users/\(user.id)"), .class("btn action-btn action-btn-icon"),
                        .title("Manage user"), .ariaLabel("Manage @\(user.username)")
                    ) {
                        Icon("i-pencil")
                    }
                    details(.class("ext-details row-menu")) {
                        summary(
                            .class("btn action-btn action-btn-icon ext-summary"), .title("More actions"),
                            .ariaLabel("More actions for @\(user.username)")
                        ) {
                            Icon("i-more")
                        }
                        div(.class("popover-panel row-menu-panel"), .role("menu")) {
                            form(
                                .method(.post), .action("/admin/courses/\(course.id)/unenroll/\(user.id)"),
                                .data(
                                    "confirm",
                                    value:
                                        "Remove @\(user.username) from \(course.code)? They lose access immediately. Their submissions and grades are kept, and you can add them back from this page."
                                )
                            ) {
                                CSRFField(token: csrfToken)
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
}
