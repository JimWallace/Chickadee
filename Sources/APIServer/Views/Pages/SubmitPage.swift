// APIServer/Views/Pages/SubmitPage.swift
//
// GET /testsetups/:id/submit: the upload form for an upload-graded assignment.

import Elementary

struct SubmitPage: HTML {
    let page: PageRequestContext
    let testSetupID: String
    let assignmentTitle: String
    /// The file input's `accept` list (`submissionAcceptAttribute`).
    let acceptAttribute: String
    /// One sentence naming what the assignment takes (`submissionAcceptHintText`).
    let acceptHintText: String
    /// The refusal of the previous upload (`?error=filetype`), or nil.
    let errorText: String?
    /// The manifest's `requiredFiles`, comma-joined, or nil when there are none.
    let requiredFilesText: String?
    let chips: SubmitChips
    /// The GitHub submit page, when this assignment offers it.
    let githubSubmitURL: String?
    /// True when both AI-assisted feedback gates are on.
    let aiFeedbackNotice: Bool
    /// The dataset files of this assignment, each a download of the
    /// student's own rows.
    var datasets: [SubmitDatasetLink] = []
    /// The course Data page, when a dataset here is in the course library.
    var dataPageHref: String?

    var body: some HTML {
        BaseLayout(title: "Submit Code", page: page) {
            h1 { "Submit to \(assignmentTitle)" }
            div(.class("chip-row")) {
                span(.class("chip")) { "Attempt \(chips.attemptNumber)" }
                if let deadlineText = chips.deadlineText {
                    span(.class("chip js-relative-time"), .data("iso", value: chips.deadlineISO ?? "")) {
                        deadlineText
                    }
                }
            }
            if aiFeedbackNotice {
                p(.class("fine-print")) {
                    "Course staff can use an AI agent, without your name, to help draft feedback on your written answers. "
                    NewTabLink(
                        href:
                            "https://github.com/JimWallace/Chickadee/blob/main/docs/ai-assisted-feedback.md#information-for-students",
                        text: "How it works "
                    )
                }
            }
            if let requiredFilesText {
                p(.class("fine-print")) {
                    "This assignment expects the following files: "
                    code { requiredFilesText }
                    ". Upload a single file, or a .zip that contains all of them."
                }
            }
            if !datasets.isEmpty {
                datasetLine
            }
            uploadForm
            if let githubSubmitURL {
                p(.class("section-note")) {
                    "You can also "
                    a(.href(githubSubmitURL)) { "submit a commit from GitHub" }
                    "."
                }
            }
        }
    }

    private var datasetLine: some HTML {
        p(.class("fine-print")) {
            "Your data: "
            for (index, dataset) in datasets.enumerated() {
                if index > 0 { ", " }
                a(.href(dataset.href)) { code { dataset.filename } }
                " (\(dataset.rowsText))"
            }
            "."
            if let dataPageHref {
                " "
                a(.href(dataPageHref)) { "About the data" }
            }
        }
    }

    private var uploadForm: some HTML {
        form(
            .class("form form--wide"), .id("submit-form"), .method(.post),
            .action("/testsetups/\(testSetupID)/submit"), .enctype(.multipartFormData)
        ) {
            CSRFField(token: page.csrfToken)
            if let errorText {
                div(.class("form-error"), .id("submit-error")) { errorText }
            } else {
                div(.class("form-error"), .id("submit-error"), .hidden) {}
            }
            div(
                .class("drop-zone"), .id("drop-zone"), .role("button"), .tabindex(0),
                .custom(name: "aria-controls", value: "file-input"),
                .custom(name: "aria-describedby", value: "drop-zone-help")
            ) {
                Icon("i-upload")
                p(.id("drop-zone-help")) { "Drag your file here, or press Enter/Space to choose" }
                input(
                    .type(.file), .name("files"), .id("file-input"),
                    .custom(name: "accept", value: acceptAttribute),
                    .data("accept-hint", value: acceptHintText), .required)
            }
            p(.class("field-note")) { acceptHintText }
            p(.class("drop-filename"), .id("drop-filename")) {}
            div {
                button(.class("btn btn-primary"), .type(.submit)) { "Submit" }
                a(.class("btn"), .href("/")) { "Cancel" }
            }
        }
    }
}
