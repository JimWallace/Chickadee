// APIServer/Views/Pages/AssignmentFeedbackPage.swift
//
// GET /instructor/:assignmentID/feedback: the staff review of AI-assisted
// feedback drafts (docs/ai-assisted-feedback.md). Every student who has
// submitted, with their feedback state; a row with text opens onto the
// student's written answers and an editor to save, release or discard it.

import Elementary

struct AssignmentFeedbackPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let assignmentID: String
    let assignmentTitle: String
    /// False when either gate is off: no agent can read or draft, but staff
    /// can still review what is already there.
    let gatesOpen: Bool
    /// The questions, once, from the starter notebook.
    let prompts: [FeedbackReviewText]
    let rows: [FeedbackReviewRow]
    /// Rows that still need a person: a draft, or a stale one.
    let reviewCount: Int
    let maxDraftLength: Int

    var body: some HTML {
        BaseLayout(title: "\(assignmentTitle) — Feedback", page: page, flash: flash) {
            div(.class("page-titlebar")) {
                h1 { "\(assignmentTitle) — Feedback" }
                a(.class("btn action-btn"), .href("/instructor/\(assignmentID)/submissions")) { "Submissions" }
            }
            p(.class("page-subtitle")) {
                "Students see only the feedback you release. "
                NewTabLink(
                    href: "https://github.com/JimWallace/Chickadee/blob/main/docs/ai-assisted-feedback.md",
                    text: "How it works "
                )
            }
            if !gatesOpen {
                FlashBanner(.warning) {
                    "AI-assisted feedback is off for this assignment, so no agent can read answers or add drafts."
                }
            }
            if !prompts.isEmpty {
                section(.class("page-section")) {
                    h2 { "Prompts" }
                    ol {
                        for prompt in prompts {
                            li {
                                for paragraph in prompt.paragraphs {
                                    p { paragraph }
                                }
                            }
                        }
                    }
                }
            }
            section(.class("page-section")) {
                h2 { "Students (\(reviewCount) to review)" }
                if rows.isEmpty {
                    p(.class("empty")) { "No submissions yet." }
                } else {
                    table(.class("results-table")) {
                        thead {
                            tr {
                                th { "Student" }
                                th { "Handle" }
                                th { "Feedback" }
                            }
                        }
                        tbody {
                            for row in rows {
                                FeedbackReviewRows(
                                    page: page, assignmentID: assignmentID, row: row, maxDraftLength: maxDraftLength)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One student's row, and the answers-and-editor row under it when the
/// feedback has text.
private struct FeedbackReviewRows: HTML {
    let page: PageRequestContext
    let assignmentID: String
    let row: FeedbackReviewRow
    let maxDraftLength: Int

    private var stateClass: String {
        switch row.state {
        case "released": "tier tier-open"
        case "stale": "tier tier-danger"
        case "draft": "tier"
        default: "tier tier-closed"
        }
    }

    var body: some HTML {
        tr {
            td { row.student }
            td { code { row.handle } }
            td { span(.class(stateClass)) { row.stateLabel } }
        }
        if row.hasText {
            tr(.class("test-output-row")) {
                td(.custom(name: "colspan", value: "3")) {
                    details(.class("test-output-details")) {
                        summary { "Answers and feedback" }
                        for answer in row.answers {
                            p(.class("card-meta")) { "Answer \(answer.index)" }
                            if answer.paragraphs.isEmpty {
                                p(.class("empty")) { "No answer" }
                            }
                            for paragraph in answer.paragraphs {
                                p { paragraph }
                            }
                        }
                        editForm
                        discardForm
                    }
                    .attributes(.custom(name: "open"), when: row.needsReview)
                }
            }
        }
    }

    private var editForm: some HTML {
        form(.method(.post), .action("/instructor/\(assignmentID)/feedback"), .class("form-stack")) {
            CSRFField(token: page.csrfToken)
            " "
            input(.type(.hidden), .name("handle"), .value(row.handle))
            " "
            label(.for("feedback-\(row.handle)")) {
                "Feedback"
                if let draftedBy = row.draftedBy {
                    " "
                    span(.class("card-meta")) { "drafted by \(draftedBy)" }
                }
            }
            " "
            textarea(
                .id("feedback-\(row.handle)"), .name("feedback"), .class("form-input"), .rows(6),
                .maxlength(maxDraftLength)
            ) { row.draftText }
            div(.class("toolbar")) {
                button(
                    .class("btn btn-primary"), .type(.submit), .name("action"), .custom(name: "value", value: "release")
                ) { "Release" }
                " "
                button(.class("btn action-btn"), .type(.submit), .name("action"), .custom(name: "value", value: "save"))
                { "Save draft" }
            }
        }
    }

    private var discardForm: some HTML {
        form(
            .method(.post), .action("/instructor/\(assignmentID)/feedback"), .class("form-flush"),
            .data(
                "confirm",
                value:
                    "Discard the feedback for \(row.handle)? The student no longer sees it, and an agent can then write a new draft."
            )
        ) {
            CSRFField(token: page.csrfToken)
            " "
            input(.type(.hidden), .name("handle"), .value(row.handle))
            " "
            input(.type(.hidden), .name("action"), .value("discard"))
            " "
            button(.class("btn action-btn action-danger"), .type(.submit)) { "Discard" }
        }
    }
}
