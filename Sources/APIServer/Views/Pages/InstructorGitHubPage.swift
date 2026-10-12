// APIServer/Views/Pages/InstructorGitHubPage.swift
//
// GET /instructor/github: the active course's GitHub organization, the
// template of each assignment that accepts GitHub submission, and every
// course repository (docs/github-submissions.md slice 4). The tab bar has no
// GitHub tab; the assignment editor links here.

import Elementary

struct InstructorGitHubPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    /// Per-course instructors may change the page; TAs may only read it.
    let canEdit: Bool
    /// The bound organization, or nil.
    let organization: InstructorGitHubOrganization?
    /// Where an organization owner installs the App.
    let installURL: String
    /// The typed organization, kept after a refused bind.
    let organizationText: String
    /// Assignments that accept GitHub submission.
    let assignments: [InstructorGitHubAssignmentRow]
    /// True when the organization's template list could not be read.
    let templatesUnavailable: Bool
    /// Every course repository, for staff.
    let repositories: [InstructorGitHubRepositoryRow]

    var body: some HTML {
        BaseLayout(title: "GitHub", page: page, flash: flash) {
            InstructorTabs(active: .github)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to set up its GitHub organization." }
                }
            } else {
                section(.class("page-section")) {
                    h2 { "GitHub organization — \(courseCode)" }
                    if let organization {
                        InstructorGitHubBoundOrganization(page: page, organization: organization, canEdit: canEdit)
                    } else {
                        p(.class("empty")) { "No organization is bound." }
                        p(.class("section-note")) {
                            "Course repositories are made in an organization that an owner binds to this course. First "
                            a(.href(installURL)) { "install the GitHub App on the organization" }
                            "."
                        }
                        if canEdit {
                            bindForm
                        }
                    }
                }
                if organization != nil {
                    templatesSection
                    repositoriesSection
                }
            }
        }
    }

    private var bindForm: some HTML {
        form(.method(.post), .action("/instructor/github/bind"), .class("form-stack")) {
            CSRFField(token: page.csrfToken)
            label(.class("form-label")) {
                "Organization"
                input(
                    .class("form-input"), .type(.text), .name("organization"), .value(organizationText),
                    .placeholder("uwaterloo-cs"), .required)
            }
            div(.class("toolbar")) {
                button(.class("btn btn-primary"), .type(.submit)) { "Bind on GitHub" }
            }
        }
    }

    private var templatesSection: some HTML {
        section(.class("page-section")) {
            h2 { "Templates" }
            if templatesUnavailable {
                p(.class("section-note")) { "The template list could not be read from GitHub." }
            }
            if assignments.isEmpty {
                p(.class("empty")) { "No assignment accepts GitHub submission." }
                p(.class("section-note")) { "Turn it on in an assignment's Student Options." }
            } else {
                table(.class("results-table")) {
                    thead {
                        tr {
                            th { "Assignment" }
                            th { "Template" }
                            th { "Repositories" }
                        }
                    }
                    tbody {
                        for row in assignments {
                            InstructorGitHubTemplateRow(page: page, row: row, canEdit: canEdit)
                        }
                    }
                }
            }
            if canEdit {
                form(.method(.post), .action("/instructor/github/archive"), .class("section-gap")) {
                    CSRFField(token: page.csrfToken)
                    div(.class("toolbar")) {
                        button(
                            .class("btn action-btn"), .type(.submit),
                            .data(
                                "confirm",
                                value: "Archive every course repository? They become read-only and stay on GitHub.")
                        ) { "Archive repositories" }
                    }
                }
            }
        }
    }

    private var repositoriesSection: some HTML {
        section(.class("page-section")) {
            h2 { "Course repositories" }
            if repositories.isEmpty {
                p(.class("empty")) { "No student has made a course repository." }
                p(.class("section-note")) {
                    "Students make one on the GitHub page of an assignment that has a template."
                }
            } else {
                table(.class("results-table")) {
                    thead {
                        tr {
                            th { "Assignment" }
                            th { "Student" }
                            th { "Repository" }
                            th { "Last push" }
                        }
                    }
                    tbody {
                        for row in repositories {
                            InstructorGitHubRepositoryLine(row: row)
                        }
                    }
                }
            }
        }
    }
}

/// The bound organization: its grants, its warnings and the unbind form.
private struct InstructorGitHubBoundOrganization: HTML {
    let page: PageRequestContext
    let organization: InstructorGitHubOrganization
    let canEdit: Bool

    var body: some HTML {
        dl(.class("detail-grid")) {
            dt { "Organization" }
            dd { a(.href(organization.url)) { organization.login } }
            for capability in organization.capabilities {
                dt { capability.label }
                dd {
                    if capability.granted {
                        span(.class("tier tier-open")) { "Granted" }
                    } else {
                        span(.class("tier tier-closed")) { "Not granted" }
                    }
                }
            }
        }
        if organization.cannotMakeRepositories {
            FlashBanner(.warning) {
                "The GitHub App on this organization cannot make course repositories. An organization owner must "
                a(.href(organization.installationSettingsURL)) { "accept its permissions on GitHub" }
                ", or an admin must add them to the App."
            }
        }
        if organization.capabilitiesUnknown {
            p(.class("section-note")) { "The permissions of the App on this organization could not be read." }
        }
        if organization.forksAllowed {
            FlashBanner(.warning) {
                "Members of this organization can fork private repositories. Turn off private forks in its settings on GitHub."
            }
        }
        if organization.forksUnknown {
            p(.class("section-note")) { "The fork setting of this organization could not be read." }
        }
        if canEdit {
            form(.method(.post), .action("/instructor/github/unbind")) {
                CSRFField(token: page.csrfToken)
                div(.class("toolbar")) {
                    button(
                        .class("btn action-btn action-danger"), .type(.submit),
                        .data(
                            "confirm",
                            value: "Unbind \(organization.login)? The course repositories stay on GitHub.")
                    ) { "Unbind" }
                }
            }
        }
    }
}

/// One assignment's template picker, or its template name for a TA.
private struct InstructorGitHubTemplateRow: HTML {
    let page: PageRequestContext
    let row: InstructorGitHubAssignmentRow
    let canEdit: Bool

    var body: some HTML {
        tr {
            td { row.title }
            td {
                if canEdit {
                    form(.method(.post), .action("/instructor/github/templates"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        input(.type(.hidden), .name("testSetupID"), .value(row.testSetupID))
                        select(
                            .class("form-input"), .name("templateID"), .ariaLabel("Template for \(row.title)")
                        ) {
                            for option in row.templateOptions {
                                Elementary.option(.value(option.value)) { option.label }
                                    .attributes(.selected, when: option.selected)
                            }
                        }
                        " "
                        button(.class("btn action-btn"), .type(.submit)) { "Save" }
                    }
                } else {
                    row.templateName ?? "None"
                }
            }
            td { String(row.repositoryCount) }
        }
    }
}

/// One course repository and its last push.
private struct InstructorGitHubRepositoryLine: HTML {
    let row: InstructorGitHubRepositoryRow

    var body: some HTML {
        tr {
            td { row.assignmentTitle }
            td { row.studentName }
            td {
                a(.href(row.repositoryURL)) { row.repositoryName }
                if row.archived {
                    " "
                    span(.class("tier tier-closed")) { "archived" }
                }
            }
            if let iso = row.lastPushedISO {
                td(.class("time js-relative-time"), .data("iso", value: iso)) { row.lastPushedText }
            } else {
                td { row.lastPushedText }
            }
        }
    }
}
