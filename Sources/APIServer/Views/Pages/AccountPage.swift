// APIServer/Views/Pages/AccountPage.swift
//
// GET /account: the signed-in user's identity, their bird (its colour and
// ring), the GitHub link, their courses and the courses open to join, and
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
            if error == "invalid" {
                p(.class("form-error"), .role("alert")) { "That course is not available." }
            }
            identitySection
            AccountBirdCard(page: page, picker: avatarPicker, invalid: avatarInvalid)
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

/// The "Your bird" card: the bird, and its Colour and Ring groups
/// (docs/student-wardrobe.md, W1; docs/avatar-species.md). The species and
/// markings are drawn, not chosen, so neither has a group.
private struct AccountBirdCard: HTML {
    let page: PageRequestContext
    let picker: AvatarPickerContext
    let invalid: Bool

    var body: some HTML {
        section(.class("page-section"), .id("bird")) {
            h2 { "Your bird" }
            p(.class("section-note")) {
                "Classmates see your bird and its handle on leaderboards and in live sessions. "
                    + "Only you and course staff can link either one to you."
            }
            if invalid {
                p(.class("form-error"), .role("alert")) { "That choice is not available." }
            }
            // `chickadee` is the card's older anchor; the save redirect still
            // names it. The hatch redirects name the section, `bird`.
            div(.class("card bird-card"), .id("chickadee")) {
                if let hatch = picker.hatch, let strip = hatch.strip {
                    AccountHatchStrip(page: page, hatch: hatch, strip: strip)
                }
                div(.class("bird-card-body")) {
                    AccountBirdHero(page: page, picker: picker)
                    AccountBirdForm(page: page, picker: picker)
                }
            }
            script(.src(page.asset("/avatar-picker.js"))) {}
        }
    }
}

/// The new bird coming out of its egg, on the first page after a hatch
/// (#2590). The egg wobbles, splits and falls away, and the bird grows out of
/// it. CSS only: under reduced motion there is no egg, only the bird. The
/// shell halves are decoration, so a screen reader hears nothing of them.
private struct AccountHatchReveal: HTML {
    let hero: AvatarPresentation

    var body: some HTML {
        span(.class("bird-hatch")) {
            Avatar(avatar: hero)
            span(.class("bird-hatch-egg"), .ariaHidden) {
                span(.class("bird-hatch-shell bird-hatch-shell--top")) {}
                span(.class("bird-hatch-shell bird-hatch-shell--bottom")) {}
            }
        }
    }
}

/// The bird at the podium size, with its handle, its species, when it hatched
/// and the hatch control.
private struct AccountBirdHero: HTML {
    let page: PageRequestContext
    let picker: AvatarPickerContext

    var body: some HTML {
        div(.class("bird-card-hero")) {
            if picker.hatch?.strip == .hatched {
                AccountHatchReveal(hero: picker.hero)
            } else {
                Avatar(avatar: picker.hero)
            }
            if !picker.handle.isEmpty {
                p { strong(.dataFlag("avatar-handle")) { picker.handle } }
            }
            p(.dataFlag("avatar-species")) {
                if picker.handle.isEmpty {
                    strong { picker.speciesName }
                } else {
                    picker.speciesName
                }
                if picker.hatch?.strip == .hatched {
                    " "
                    span(.class("tier")) { "New" }
                }
            }
            if !picker.hatchedText.isEmpty {
                p(.class("text-muted"), .dataFlag("avatar-hatched")) { picker.hatchedText }
            }
            if let hatch = picker.hatch {
                AccountHatchControl(page: page, hatch: hatch)
            }
        }
    }
}

/// The strip across the top of the bird card: the confirm before a hatch, or
/// the new bird after one.
private struct AccountHatchStrip: HTML {
    let page: PageRequestContext
    let hatch: AvatarHatchContext
    let strip: AvatarHatchStrip

    var body: some HTML {
        switch strip {
        case .confirm:
            div(.class("bird-card-strip")) {
                div(.ariaHidden) {
                    Avatar(avatar: hatch.current)
                    " → "
                    span(.class("swatch-none")) { "?" }
                }
                div {
                    p { strong { "Hatch a new bird?" } }
                    p {
                        (hatch.handle == nil
                            ? "You’ll get a different species" : "You’ll get a new handle and a different species")
                            + ", with random colours, markings, face and hat. Your backdrop and ring stay. "
                            + "This uses 1 of the \(hatch.left) you have left this term."
                    }
                }
                div(.class("toolbar")) {
                    form(.method(.post), .action("/account/avatar/hatch")) {
                        CSRFField(token: page.csrfToken)
                        " "
                        button(.class("btn btn-primary"), .type(.submit)) { "Hatch" }
                    }
                    a(.class("btn"), .href("/account#bird")) { "Keep my \(hatch.speciesWord)" }
                }
            }
        case .hatched:
            div(.class("bird-card-strip"), .role("status")) {
                div {
                    p { strong { hatch.meetTitle } }
                    p { hatch.meetBody }
                }
                div(.class("toolbar")) {
                    AccountRestoreForm(page: page, hatch: hatch, linkStyled: false)
                    a(.class("btn btn-primary"), .href("/account#bird")) { "Keep it" }
                }
            }
        }
    }
}

/// The hatch control under the hero bird: the button, the caption and, while
/// a previous bird exists, the way back to it. With none left, the button
/// stays, disabled, and the caption says when more come.
private struct AccountHatchControl: HTML {
    let page: PageRequestContext
    let hatch: AvatarHatchContext

    var body: some HTML {
        div(.class("bird-card-hatch")) {
            if hatch.canHatch {
                a(.class("btn"), .href("/account?hatch=confirm#bird")) {
                    Icon("i-refresh")
                    " Hatch a new bird"
                }
            } else {
                button(.class("btn"), .type(.button), .disabled) {
                    Icon("i-refresh")
                    " Hatch a new bird"
                }
            }
            p(.class("field-note field-note--muted")) { hatch.caption }
            if hatch.previous != nil, hatch.strip != .hatched {
                AccountRestoreForm(page: page, hatch: hatch, linkStyled: true)
            }
        }
    }
}

/// "Go back to my cardinal": puts the previous bird back.
private struct AccountRestoreForm: HTML {
    let page: PageRequestContext
    let hatch: AvatarHatchContext
    /// The small link-styled button under the caption, or the strip's button
    /// with the previous bird in it.
    let linkStyled: Bool

    var body: some HTML {
        form(.method(.post), .action("/account/avatar/restore")) {
            CSRFField(token: page.csrfToken)
            " "
            if linkStyled {
                button(.class("btn-link"), .type(.submit)) { "Go back to my \(hatch.previousSpeciesWord ?? "")" }
            } else {
                button(.class("btn"), .type(.submit)) {
                    if let previous = hatch.previous { Avatar(avatar: previous) }
                    "Go back to my \(hatch.previousSpeciesWord ?? "")"
                }
            }
        }
    }
}

/// The Colour and Ring groups and the Save button. The live preview updates
/// the hero bird.
private struct AccountBirdForm: HTML {
    let page: PageRequestContext
    let picker: AvatarPickerContext

    var body: some HTML {
        // The style attribute sets only custom properties, which the UI
        // rules allow. The ring samples inherit all three, so they draw
        // the ring on the previewed backdrop in the previewed colours.
        form(
            .method(.post), .action("/account/avatar"), .class("bird-card-groups"),
            .data("avatar-picker", value: ".bird-card .avatar-xl"),
            .custom(
                name: "style",
                value: "--av-backdrop: var(\(picker.backdropToken)); --av-cap: var(\(picker.capToken)); "
                    + "--av-accent: var(\(picker.accentToken))")
        ) {
            CSRFField(token: page.csrfToken)
            fieldset(.class("fieldset-plain")) {
                legend { "Colour" }
                p(.class("field-note field-note--muted")) { picker.colourNote }
                div(.class("swatch-row")) {
                    for (position, option) in picker.feathers.enumerated() {
                        if position > 0 { " " }
                        AccountBirdSwatch(option: option)
                    }
                }
                fieldset(.class("fieldset-plain fieldset-plain--nested")) {
                    legend { "Backdrop" }
                    div(.class("swatch-row")) {
                        for (position, option) in picker.backdrops.enumerated() {
                            if position > 0 { " " }
                            AccountBackdropSwatch(option: option)
                        }
                    }
                }
            }
            AccountRingGroup(picker: picker)
            div(.class("toolbar")) {
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Save" }
                    " "
                    // avatar-picker.js shows it once a choice changes.
                    button(.class("btn"), .type(.reset), .hidden) { "Undo changes" }
                }
                p(.class("field-note field-note--muted")) { "Species and markings come with your bird." }
            }
        }
    }
}

/// One backdrop choice: a filled disc. The name is for screen readers; the
/// colour is the sample.
private struct AccountBackdropSwatch: HTML {
    let option: AvatarPickerOption

    var body: some HTML {
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
            span(.class("visually-hidden")) { option.label }
            " "
        }
    }
}

/// The Ring group: the open rings as radios, then the rings not open yet as
/// plain items. Staff see the staff ring and a note instead.
private struct AccountRingGroup: HTML {
    let picker: AvatarPickerContext

    var body: some HTML {
        fieldset(.class("fieldset-plain")) {
            legend { "Ring" }
            if picker.isStaff {
                div(.class("toolbar")) {
                    AccountRingSample(token: picker.hero.borderToken, ringRef: picker.hero.ringSymbolRef)
                    p(.class("field-note")) {
                        "Course staff wear the staff ring in every course, so students can tell who’s staff. "
                            + "It can’t be changed."
                    }
                }
            } else {
                p(.class("field-note field-note--muted")) { "Worn around your bird everywhere it appears." }
                div(.class("swatch-row")) {
                    for (position, option) in picker.rings.enumerated() {
                        if position > 0 { " " }
                        AccountBorderSwatch(option: option)
                    }
                }
                if !picker.lockedRings.isEmpty {
                    div(.class("bird-locked")) {
                        p(.class("field-note"), .id("bird-locked-label")) { "Not open yet" }
                        ul(.custom(name: "aria-labelledby", value: "bird-locked-label")) {
                            for option in picker.lockedRings {
                                li(.data("av-season", value: option.season)) {
                                    AccountRingSample(token: option.token, ringRef: option.ringRef)
                                    " "
                                    Icon("i-lock")
                                    " \(option.label)"
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One colourway choice: the student's own bird drawn in it. The radio
/// carries the six tone tokens and the three layer references the live
/// preview sets. Every colourway offered is of the student's own species, so
/// the plumage, tuft and wing references never change the bird's art.
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

/// One open ring choice: the ring drawn in the student's own colours, which
/// it inherits from the form.
private struct AccountBorderSwatch: HTML {
    let option: AvatarPickerOption

    var body: some HTML {
        label(.class("swatch")) {
            " "
            input(
                .type(.radio), .data("av-season", value: option.season), .data("av-ring", value: option.ringRef),
                .name("border"), .value(option.value), .data("av-token", value: option.token)
            )
            .attributes(.checked, when: option.checked)
            " "
            if option.isNone {
                span(.class("swatch-sample swatch-none"), .ariaHidden) {}
            } else {
                AccountRingSample(token: option.token, ringRef: option.ringRef)
            }
            " "
            span(.class("swatch-name")) { option.label }
            " "
        }
    }
}

/// A ring drawn on the backdrop. A custom property only: the accent, cap and
/// backdrop come from the form, so the sample follows the preview.
private struct AccountRingSample: HTML {
    let token: String
    let ringRef: String

    var body: some HTML {
        SVG.svg(
            .class("swatch-sample"), .custom(name: "viewBox", value: "0 0 64 64"), .ariaHidden,
            .custom(name: "style", value: "--av-border: var(\(token))")
        ) {
            SVG.use(.href("#av-backdrop")) {}
            SVG.use(.href(ringRef)) {}
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

/// A course the user is enrolled in: its slip days and the Leave course
/// action. The handle names the bird, so it is on the bird card.
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
