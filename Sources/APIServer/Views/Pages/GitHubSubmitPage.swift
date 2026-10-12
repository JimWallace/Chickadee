// APIServer/Views/Pages/GitHubSubmitPage.swift
//
// GET /testsetups/:id/github: submit a commit from a GitHub repository
// (docs/github-submissions.md slice 3). The student picks a repository and a
// branch, the page shows that branch's head commit, and the form posts that
// exact SHA. In course-repository mode (slice 4) the page offers to make the
// student's repository first.

import Elementary

struct GitHubSubmitPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let testSetupID: String
    let assignmentTitle: String
    let chips: SubmitChips
    let state: GitHubSubmitState

    var body: some HTML {
        BaseLayout(title: "Submit from GitHub", page: page, flash: flash) {
            h1 { "Submit to \(assignmentTitle) from GitHub" }
            div(.class("chip-row")) {
                span(.class("chip")) { "Attempt \(chips.attemptNumber)" }
                if let deadlineText = chips.deadlineText {
                    " "
                    span(.class("chip js-relative-time"), .data("iso", value: chips.deadlineISO ?? "")) {
                        deadlineText
                    }
                }
            }
            if let errorText = state.errorText {
                div(.class("form-error"), .role("alert")) { errorText }
            }
            if let starter = state.starter, !state.courseRepositoryMode {
                section(.class("page-section")) {
                    h2 { "Starter repository" }
                    p(.class("section-intro")) {
                        "Make a private copy of "
                        a(.href(starter.url)) { starter.name }
                        " with "
                        strong { "Use this template" }
                        ", then submit from it."
                    }
                }
            }
            if state.needsLink {
                p {
                    "Link a GitHub account on your "
                    a(.href("/account")) { "account page" }
                    " first."
                }
            }
            if let installURL = state.installURL {
                p {
                    "Install the GitHub App on your GitHub account, and give it access to the repository you submit from."
                }
                p { a(.class("btn btn-primary"), .href(installURL)) { "Install on GitHub" } }
            }
            if state.courseRepositoryMode {
                courseRepositorySection
            }
            if state.loaded {
                repositoryChooser
            }
            if let commit = state.commit {
                section(.class("page-section")) {
                    h2 { "Commit" }
                    dl(.class("detail-grid")) {
                        dt { "Repository" }
                        dd { commit.repositoryName }
                        dt { "Commit" }
                        dd {
                            a(.href(commit.commitURL)) { code { commit.shortSHA } }
                            " \(commit.summary)"
                        }
                    }
                    if state.notFromStarter {
                        p(.class("section-note")) { "This repository was not made from the starter repository." }
                    }
                    form(.method(.post), .action("/testsetups/\(testSetupID)/github"), .class("inline-form")) {
                        CSRFField(token: page.csrfToken)
                        " "
                        input(.type(.hidden), .name("repositoryID"), .value(commit.repositoryID))
                        " "
                        input(.type(.hidden), .name("sha"), .value(commit.sha))
                        " "
                        input(.type(.hidden), .name("branch"), .value(commit.branch))
                        " "
                        button(.class("btn btn-primary"), .type(.submit)) { "Submit commit \(commit.shortSHA)" }
                    }
                }
            }
            p(.class("section-note")) {
                "To submit files from your computer, use the "
                a(.href("/testsetups/\(testSetupID)/submit")) { "upload form" }
                "."
            }
        }
    }

    private var courseRepositorySection: some HTML {
        section(.class("page-section")) {
            h2 { "Course repository" }
            if let repository = state.courseRepository {
                dl(.class("detail-grid")) {
                    dt { "Repository" }
                    dd { a(.href(repository.url)) { repository.name } }
                }
                if !repository.invited {
                    p(.class("section-note")) { "The invitation to this repository was not sent." }
                    repositoryForm(label: "Resend invitation", buttonClass: "btn")
                }
            }
            if state.canMakeCourseRepository {
                p(.class("empty")) { "You have no course repository for this assignment." }
                p(.class("section-note")) {
                    "Chickadee makes a private repository from the course template and invites your GitHub account to it."
                }
                repositoryForm(label: "Make my repository", buttonClass: "btn btn-primary")
            }
        }
    }

    private func repositoryForm(label: String, buttonClass: String) -> some HTML {
        form(
            .method(.post), .action("/testsetups/\(testSetupID)/github/repository"), .class("inline-form")
        ) {
            CSRFField(token: page.csrfToken)
            " "
            button(.class(buttonClass), .type(.submit)) { label }
        }
    }

    @HTMLBuilder private var repositoryChooser: some HTML {
        if state.repositories.isEmpty {
            p(.class("empty")) { "No repository is available." }
            if state.courseRepositoryMode {
                p(.class("section-note")) { "Accept the invitation to your course repository on GitHub." }
            } else {
                p(.class("section-note")) { "Give the GitHub App access to a repository that you own." }
                p { a(.class("btn"), .href(state.configureURL ?? "")) { "Choose repositories on GitHub" } }
            }
        } else {
            form(.class("form form--wide"), .method(.get), .action("/testsetups/\(testSetupID)/github")) {
                label(.class("form-label")) {
                    "Repository "
                    select(.class("form-input"), .name("repo"), .dataFlag("ck-submit-on-change")) {
                        option(.value("")) { "Choose a repository" }
                        for repository in state.repositories {
                            option(.value(repository.value)) { repository.label }
                                .attributes(.selected, when: repository.selected)
                        }
                    }
                    " "
                }
                if !state.branches.isEmpty {
                    " "
                    label(.class("form-label")) {
                        "Branch "
                        select(.class("form-input"), .name("branch"), .dataFlag("ck-submit-on-change")) {
                            for branch in state.branches {
                                option(.value(branch.value)) { branch.label }
                                    .attributes(.selected, when: branch.selected)
                            }
                        }
                        " "
                    }
                }
                div {
                    button(.class("btn"), .type(.submit)) { "Show commit" }
                }
            }
            if !state.courseRepositoryMode {
                p(.class("section-note")) {
                    a(.href(state.configureURL ?? "")) { "Choose repositories on GitHub" }
                    " to add one to this list."
                }
            }
        }
    }
}
