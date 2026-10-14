// APIServer/Views/Pages/AccountPage.swift
//
// GET /account: the signed-in user's identity, their bird's species, backdrop
// and border, the GitHub link, their courses and the courses open to join, and
// the personal-data export (#557). The plain student page exemplar
// (docs/ui-design.md).

import Core
import Elementary

struct AccountPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let username: String
    let preferredName: String?
    /// The heading beside the avatar. See `accountIdentityName`.
    let identityName: String
    /// The username under the heading, nil when the heading already is it.
    let identitySecondary: String?
    /// The user's own bird, decorative beside their name.
    let avatar: AvatarPresentation
    let avatarPicker: AvatarPickerContext
    /// A posted avatar choice was refused.
    let avatarInvalid: Bool
    let studentID: String?
    let email: String?
    let enrolledCourses: [AccountCourseRow]
    let availableCourses: [AccountCourseRow]
    /// The `?error=` query; "invalid" names a course that cannot be joined.
    let error: String?
    /// The data export (#557): "none" | "pending" | "complete" | "failed".
    let exportStatus: String
    let exportRequestedAtDisplay: String?
    let exportCompletedAtDisplay: String?
    let exportCanRequest: Bool
    let exportNotice: String?
    let exportError: String?
    /// Whether the GitHub section shows: a link exists, or one can be made.
    let showGitHub: Bool
    /// The linked GitHub login, or nil when no account is linked.
    let githubLogin: String?

    var body: some HTML {
        BaseLayout(title: "My Account", page: page, flash: flash) {
            h1 { "My Account" }
            AvatarSprite(page: page)
            if error == "invalid" {
                p(.class("form-error"), .role("alert")) { "That course is not available." }
            }
            identitySection
            AccountAvatarPicker(page: page, picker: avatarPicker, invalid: avatarInvalid)
            if showGitHub {
                AccountGitHubBlock(page: page, login: githubLogin)
            }
            section(.class("page-section")) {
                h2 { "My courses" }
                if enrolledCourses.isEmpty {
                    p(.class("empty")) {
                        "You are not enrolled in any courses. "
                        a(.href("/enroll")) { "Browse available courses" }
                    }
                } else {
                    table(.class("results-table section-items")) {
                        colgroup {
                            col(.class("section-items-tile"))
                            col()
                            col(.class("section-items-status"))
                            col(.class("section-items-actions"))
                        }
                        thead(.class("visually-hidden")) {
                            tr {
                                th { "Code" }
                                th { "Name" }
                                th { "Enrolment" }
                                th { span(.class("visually-hidden")) { "Actions" } }
                            }
                        }
                        tbody {
                            for course in enrolledCourses {
                                AccountEnrolledCourseRow(page: page, course: course)
                            }
                        }
                    }
                }
            }
            availableSection
            dataSection
        }
    }

    private var identitySection: some HTML {
        section(.class("page-section")) {
            h2 { "Account info" }
            div(.class("card section-gap")) {
                div(.class("account-identity")) {
                    Avatar(avatar: avatar)
                    div {
                        strong { identityName }
                        if let identitySecondary {
                            " "
                            span(.class("text-muted")) { identitySecondary }
                        }
                    }
                }
                dl(.class("detail-grid")) {
                    div {
                        dt { "Username" }
                        dd { strong { username } }
                    }
                    if let preferredName {
                        div {
                            dt { "Preferred name" }
                            dd { preferredName }
                        }
                    }
                    if let studentID {
                        div {
                            dt { "Student ID" }
                            dd { studentID }
                        }
                    }
                    if let email {
                        div {
                            dt { "Email" }
                            dd { email }
                        }
                    }
                }
            }
        }
    }

    private var availableSection: some HTML {
        section(.class("page-section")) {
            h2 { "Available courses" }
            if availableCourses.isEmpty {
                p(.class("empty")) { "There are no other courses open to join right now." }
            } else {
                table(.class("results-table section-items")) {
                    colgroup {
                        col(.class("section-items-tile"))
                        col()
                        col(.class("section-items-actions"))
                    }
                    thead(.class("visually-hidden")) {
                        tr {
                            th { "Code" }
                            th { "Name" }
                            th { span(.class("visually-hidden")) { "Actions" } }
                        }
                    }
                    tbody {
                        for course in availableCourses {
                            AccountAvailableCourseRow(page: page, course: course)
                        }
                    }
                }
            }
        }
    }

    private var dataSection: some HTML {
        section(.class("page-section")) {
            h2 { "Your data" }
            if exportNotice == "started" {
                FlashBanner(.neutral) {
                    "Your data export is being prepared. This page will refresh when it is ready."
                }
            } else if exportNotice == "in_progress" {
                FlashBanner(.neutral) {
                    "Your data export is already being prepared. This page will refresh when it is ready."
                }
            }
            if exportError == "rate_limited" {
                p(.class("form-error"), .role("alert")) {
                    "You can request one data export per day. Please try again later."
                }
            } else if exportError == "not_ready" {
                p(.class("form-error"), .role("alert")) { "Your data export is not ready to download yet." }
            }
            switch exportStatus {
            case "pending":
                p(.id("export-pending")) {
                    span(.class("tier tier-preview")) { "In progress" }
                    " Requested \(exportRequestedAtDisplay ?? ""). Preparing your export can take a few minutes."
                }
                script(.src(page.asset("/account-export.js"))) {}
            case "complete":
                p { a(.class("btn btn-primary"), .href("/account/export/download")) { "Download your export" } }
                p {
                    "Prepared \(exportCompletedAtDisplay ?? ""). Downloads are available for three days after "
                        + "the export is prepared, then the archive is deleted from the server."
                }
            case "failed":
                p(.class("form-error"), .role("alert")) { "Your last export attempt failed. Please try again." }
            default:
                ""
            }
            p {
                "Request a copy of the personal information Chickadee holds about you: your profile, course "
                    + "enrollments, submissions (including the files you uploaded), grading results, and account "
                    + "activity records — delivered as a single zip archive. Limit one export per day."
            }
            if exportCanRequest {
                form(.method(.post), .action("/account/export"), .class("inline-form")) {
                    CSRFField(token: page.csrfToken)
                    " "
                    button(.class("btn btn-primary"), .type(.submit)) { "Request data export" }
                }
            }
        }
    }
}

/// The species, backdrop and border choices (docs/student-wardrobe.md, W1;
/// docs/avatar-species.md, A2).
private struct AccountAvatarPicker: HTML {
    let page: PageRequestContext
    let picker: AvatarPickerContext
    let invalid: Bool

    var body: some HTML {
        section(.class("page-section"), .id("chickadee")) {
            h2 { "Bird" }
            if invalid {
                p(.class("form-error"), .role("alert")) { "That choice is not available." }
            }
            // The style attribute sets only custom properties, which the UI
            // rules allow. The ring samples inherit all three, so they draw
            // the ring on the previewed backdrop in the previewed colours.
            form(
                .method(.post), .action("/account/avatar"),
                .data("avatar-picker", value: ".account-identity .avatar"),
                .custom(
                    name: "style",
                    value: "--av-backdrop: var(\(picker.backdropToken)); --av-cap: var(\(picker.capToken)); "
                        + "--av-accent: var(\(picker.accentToken))")
            ) {
                CSRFField(token: page.csrfToken)
                fieldset(.class("fieldset-plain")) {
                    legend { "Species" }
                    for group in picker.birds {
                        fieldset(.class("fieldset-plain fieldset-plain--nested")) {
                            legend { group.species }
                            div(.class("swatch-row")) {
                                for (position, option) in group.options.enumerated() {
                                    if position > 0 { " " }
                                    AccountBirdSwatch(option: option)
                                }
                            }
                        }
                    }
                    p(.class("field-note")) { "Your handle stays." }
                }
                fieldset(.class("fieldset-plain")) {
                    legend { "Backdrop" }
                    div(.class("swatch-row")) {
                        for (position, option) in picker.backdrops.enumerated() {
                            if position > 0 { " " }
                            label(.class("swatch")) {
                                " "
                                input(
                                    .type(.radio), .name("backdrop"), .value(option.value),
                                    .data("av-token", value: option.token)
                                )
                                .attributes(.checked, when: option.checked)
                                " "
                                // A custom property only, as on the form.
                                span(
                                    .class("swatch-sample swatch-backdrop"), .ariaHidden,
                                    .custom(name: "style", value: "--av-backdrop: var(\(option.token))")
                                ) {}
                                " "
                                span(.class("swatch-name")) { option.label }
                                " "
                            }
                        }
                    }
                }
                fieldset(.class("fieldset-plain")) {
                    legend { "Border" }
                    if picker.isStaff {
                        p(.class("field-note")) { "Course staff wear the staff ring." }
                    } else {
                        div(.class("swatch-row")) {
                            for (position, option) in picker.borders.enumerated() {
                                if position > 0 { " " }
                                AccountBorderSwatch(picker: picker, option: option)
                            }
                        }
                        p(.class("field-note")) { "Locked rings will be earned through course achievements." }
                        p(.class("field-note")) { "A seasonal ring can be chosen only during its term." }
                    }
                }
                button(.class("btn btn-primary"), .type(.submit)) { "Save" }
            }
            script(.src(page.asset("/avatar-picker.js"))) {}
        }
    }
}

/// One colourway choice: the student's own bird drawn in it, at the roster
/// size so the species reads. The radio carries the six tone tokens and the
/// three layer references the live preview sets: plumage, tuft or crest, and
/// the wing, because a species may draw a pattern with its own art.
private struct AccountBirdSwatch: HTML {
    let option: AvatarBirdOption

    var body: some HTML {
        label(.class("swatch")) {
            " "
            input(
                .type(.radio), .name("cap"), .value(option.value),
                .data("av-cap", value: option.presentation.capToken),
                .data("av-wing", value: option.presentation.wingToken),
                .data("av-body", value: option.presentation.bodyToken),
                .data("av-bib", value: option.presentation.bibToken),
                .data("av-beak", value: option.presentation.beakToken),
                .data("av-mark", value: option.presentation.markToken),
                .data("av-plumage", value: option.presentation.plumageSymbolRef),
                .data("av-tuft", value: option.presentation.tuftSymbolRef),
                .data("av-wing-art", value: option.presentation.wingSymbolRef)
            )
            .attributes(.checked, when: option.checked)
            " "
            span(.class("swatch-sample swatch-bird"), .ariaHidden) {
                Avatar(avatar: option.presentation)
            }
            " "
            span(.class("swatch-name")) { option.label }
            " "
        }
    }
}

/// One border choice: the ring drawn in the student's own colours, which it
/// inherits from the form.
private struct AccountBorderSwatch: HTML {
    let picker: AvatarPickerContext
    let option: AvatarPickerOption

    var body: some HTML {
        label(.class("swatch")) {
            " "
            input(
                .type(.radio), .data("av-season", value: option.season), .data("av-ring", value: option.ringRef),
                .name("border"), .value(option.value), .data("av-token", value: option.token)
            )
            .attributes(.checked, when: option.checked)
            .attributes(.disabled, when: option.isLocked)
            " "
            if option.isNone {
                span(.class("swatch-sample swatch-none"), .ariaHidden) {}
            } else {
                // A custom property only. The accent, cap and backdrop come
                // from the form, so the sample follows the preview.
                SVG.svg(
                    .class("swatch-sample"), .custom(name: "viewBox", value: "0 0 64 64"), .ariaHidden,
                    .custom(name: "style", value: "--av-border: var(\(option.token))")
                ) {
                    SVG.use(.href("#av-backdrop")) {}
                    SVG.use(.href(option.ringRef)) {}
                }
            }
            " "
            span(.class("swatch-name")) { option.label }
            " "
        }
    }
}

/// The GitHub section: the linked login and its Unlink menu, or the Link
/// button.
private struct AccountGitHubBlock: HTML {
    let page: PageRequestContext
    let login: String?

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "GitHub" }
            if let login {
                div(.class("card section-gap")) {
                    div(.class("toolbar toolbar--end")) {
                        span(.class("tier tier-open")) { "Linked" }
                        RowMenu(for: "your GitHub link") {
                            form(.method(.post), .action("/account/github/unlink")) {
                                CSRFField(token: page.csrfToken)
                                " "
                                button(
                                    .class("row-menu-item row-menu-item--danger"), .type(.submit),
                                    .role("menuitem"),
                                    .data("confirm", value: "Unlink the GitHub account \(login)?")
                                ) {
                                    " "
                                    Icon("i-trash")
                                    "Unlink"
                                }
                            }
                        }
                    }
                    dl(.class("detail-grid")) {
                        div {
                            dt { "GitHub login" }
                            dd { strong { login } }
                        }
                    }
                }
            } else {
                p(.class("empty")) { "No GitHub account linked." }
                p(.class("section-note")) { "Chickadee keeps only your GitHub user ID and login." }
                form(.method(.post), .action("/account/github/link"), .class("inline-form")) {
                    CSRFField(token: page.csrfToken)
                    " "
                    button(.class("btn btn-primary"), .type(.submit)) { "Link GitHub account" }
                }
            }
        }
    }
}

/// A course the user is enrolled in: its handle, slip days, and the Change
/// handle and Leave course actions.
private struct AccountEnrolledCourseRow: HTML {
    let page: PageRequestContext
    let course: AccountCourseRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "outline")) { Icon("i-book") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    strong { course.code }
                    if let termLabel = course.termLabel { " \(termLabel)" }
                }
                div(.class("item-details")) { course.name }
                if let handle = course.handle {
                    div(.class("item-details"), .dataFlag("avatar-handle")) { "Class handle: \(handle)" }
                    if let choice = course.handleChoice, choice.isLocked {
                        div(.class("item-details")) { "Your handle is set for this course." }
                        if choice.wasLocked {
                            div(.class("item-details"), .role("status")) {
                                "It was set before your last choice arrived."
                            }
                        }
                    }
                }
                if let slipDaysText = course.slipDaysText {
                    div(.class("item-details")) { slipDaysText }
                }
                if course.enrollmentMode == "auto" {
                    div(.class("item-details")) { "Auto-enrolled. Contact your instructor to be removed." }
                } else if course.enrollmentMode != "open" {
                    div(.class("item-details")) { "Managed by your instructor. Contact them to be removed." }
                }
            }
            td(.class("item-status")) {
                if course.enrollmentMode == "auto" {
                    span(.class("tier tier-closed"), .title("Auto-enrolled — contact your instructor to be removed")) {
                        "Auto"
                    }
                } else if course.enrollmentMode != "open" {
                    span(.class("tier tier-closed"), .title("Managed by instructor — contact them to be removed")) {
                        "Managed"
                    }
                }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    if let choice = course.handleChoice, choice.canChoose {
                        AccountHandleChooser(page: page, course: course, choice: choice)
                    }
                    if course.enrollmentMode == "open" {
                        leaveMenu
                    }
                }
            }
        }
    }

    private var leaveMenu: some HTML {
        RowMenu(for: course.code) {
            form(.method(.post), .action("/account/unenroll/\(course.id)")) {
                CSRFField(token: page.csrfToken)
                " "
                button(
                    .class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem"),
                    .data("confirm", value: "Leave \(course.code)?")
                ) {
                    " "
                    Icon("i-trash")
                    "Leave course"
                }
            }
        }
    }
}

/// The Change handle panel: the current handle and two alternates, each
/// beside the student's own bird.
private struct AccountHandleChooser: HTML {
    let page: PageRequestContext
    let course: AccountCourseRow
    let choice: AccountHandleChoice

    var body: some HTML {
        details(.class("ext-details form-flush")) {
            summary(.class("btn action-btn ext-summary")) { "Change handle" }
            form(.method(.post), .action("/account/handle/\(course.id)"), .class("ext-panel")) {
                CSRFField(token: page.csrfToken)
                if choice.wasTaken {
                    p(.class("form-error"), .role("alert")) { "That one was just taken. Here are two more." }
                }
                p(.class("field-note")) { "You can change it once, until classmates see it." }
                div(
                    .class("checkbox-list"), .role("radiogroup"), .ariaLabel("Class handle for \(course.code)")
                ) {
                    for (position, option) in choice.options.enumerated() {
                        if position > 0 { " " }
                        label(.class("checkbox-row")) {
                            " "
                            input(.type(.radio), .name("handle"), .value(option.handle))
                                .attributes(.checked, when: option.isCurrent)
                            " "
                            Avatar(avatar: option.avatar)
                            " \(option.handle) "
                            if option.isCurrent {
                                span(.class("chip")) { "Current" }
                                " "
                            }
                        }
                    }
                }
                div(.class("ext-panel-actions")) {
                    button(.class("btn action-btn"), .type(.submit)) { "Save" }
                }
            }
        }
        .attributes(.custom(name: "open"), when: choice.wasTaken)
    }
}

/// An open course the user may join.
private struct AccountAvailableCourseRow: HTML {
    let page: PageRequestContext
    let course: AccountCourseRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "outline")) { Icon("i-book") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    strong { course.code }
                    if let termLabel = course.termLabel { " \(termLabel)" }
                }
                div(.class("item-details")) { course.name }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    form(.method(.post), .action("/account/enroll"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        " "
                        input(.type(.hidden), .name("courseID"), .value(course.id))
                        " "
                        button(.class("btn action-btn"), .type(.submit)) { "Join" }
                    }
                }
            }
        }
    }
}
