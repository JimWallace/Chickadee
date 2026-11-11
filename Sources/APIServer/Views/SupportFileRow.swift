// APIServer/Views/SupportFileRow.swift
//
// One support file in the Files table of the assignment editors: a data
// fixture (CSV, JSON, ...) bundled with the assignment, with its per-student
// dataset control (docs/datasets.md). The create page and the edit body render
// the same markup, and Public/support-files.js drives both.
//
// A file attached from the course dataset library is a dataset, not a support
// file: the edit body lists it in its own Datasets table, and this row then
// names the dataset and its version and offers the library's actions
// (docs/datasets-course-library.md §4.5).

import Elementary

struct SupportFileRow: HTML {
    let file: EditableSuiteRow

    var body: some HTML {
        tr(.data("support-file", value: file.name)) {
            if let attachment {
                td { DatasetNameCell(attachment: attachment) }
            } else {
                td { strong { "Support file" } }
            }
            td {
                a(.href(file.url)) { code { file.name } }
                datasetControl
                if let library = file.library {
                    SupportFileLibraryControl(filename: file.name, library: library)
                }
            }
            td(.class("time")) {
                if let attachment {
                    AttachedDatasetActions(filename: file.name, attachment: attachment)
                } else {
                    button(
                        .class("btn action-btn action-danger js-support-file-delete-btn"), .type(.button),
                        .data("filename", value: file.name)
                    ) { "Remove" }
                }
            }
        }
    }

    private var attachment: SupportFileLibraryState.Attachment? { file.library?.attachment }

    private var isAttached: Bool { attachment != nil }

    /// `hidden` on the fields that only mean something for a dataset.
    private var hiddenUnlessDataset: [MarkupAttribute<HTMLTag.span>] {
        file.isDataset ? [] : [.hidden]
    }

    /// `hidden` on the sample fields, which mean nothing for a partition: a
    /// partition has no sample, and the panel has no field for its parts.
    private var hiddenUnlessSampled: [MarkupAttribute<HTMLTag.span>] {
        file.isDataset && file.datasetPartCount == nil ? [] : [.hidden]
    }

    /// `disabled` on the derivation inputs when an agent wrote steps the panel
    /// cannot represent.
    private var disabledUnlessEditable: [MarkupAttribute<HTMLTag.input>] {
        file.datasetTransformsEditable ? [] : [.disabled]
    }

    private var datasetControl: some HTML {
        div(.class("dataset-control")) {
            label(.class("dataset-toggle")) {
                " "
                // An attached file always has a spec; detach ends it. A
                // partition is not a sample, so this box does not end it.
                input(
                    attributes: [.type(.checkbox), .class("js-dataset-toggle")] + (file.isDataset ? [.checked] : [])
                        + (isAttached || file.datasetPartCount != nil ? [.disabled] : [])
                        + (isAttached ? [.data("lock", value: "attached")] : []))
                // One label for a sample and a partition, so it stays true when
                // the panel repaints a spec that changed after the page loaded.
                " Per-student data"
            }
            " "
            span(attributes: [.class("dataset-size-field js-dataset-size-field")] + hiddenUnlessSampled) {
                " "
                input(
                    .type(.number), .min(1), .step(1), .class("form-input input-sm dataset-size js-dataset-size"),
                    .value(file.datasetSampleSizeText), .ariaLabel("Rows per student from \(file.name)"))
                " rows per student"
            }
            " "
            span(attributes: [.class("dataset-size-field js-dataset-stratum-field")] + hiddenUnlessSampled) {
                "balanced across "
                input(
                    .type(.text), .class("form-input input-sm dataset-stratum js-dataset-stratum"),
                    .value(file.datasetStratumColumnOrEmpty), .placeholder("column (optional)"),
                    .ariaLabel("Column to balance the sample of \(file.name) across"))
                " "
            }
            " "
            span(attributes: [.class("dataset-size-field js-dataset-blank-field")] + hiddenUnlessSampled) {
                "blanking "
                input(
                    attributes: [
                        .type(.text), .class("form-input input-sm dataset-stratum js-dataset-blank-columns"),
                        .value(file.datasetBlankColumnsOrEmpty), .placeholder("columns (optional)"),
                    ] + disabledUnlessEditable + [.ariaLabel("Columns to blank values in for \(file.name)")])
                " in "
                input(
                    attributes: [
                        .type(.number), .min(1), .max(100), .step(1),
                        .class("form-input input-sm dataset-size js-dataset-blank-percent"),
                        .value(file.datasetBlankPercentText),
                    ] + disabledUnlessEditable + [.ariaLabel("Percent of rows to blank for \(file.name)")])
                " % of rows"
            }
            " "
            // Always rendered, so the panel can show it when a spec becomes
            // a partition after the page loads. The panel sets the count.
            span(
                attributes: [.class("dataset-note js-dataset-partition-note")]
                    + (file.datasetPartCount == nil ? [.hidden] : [])
            ) {
                "Split into "
                span(.class("js-dataset-part-count")) { file.datasetPartCount.map(String.init) ?? "" }
                " parts, dealt to students in turn — edit it with set_dataset."
            }
            " "
            // Always rendered, so the panel can show it when a file becomes a
            // dataset after the page loads. The panel repaints the text.
            span(attributes: [.class("dataset-note js-dataset-delivery")] + hiddenUnlessDataset) {
                file.datasetDeliveryNoteText
            }
            " "
            if file.datasetPartCount == nil, !file.datasetTransformsEditable {
                span(.class("dataset-note")) {
                    "Derivation steps authored by an agent — edit them with set_dataset."
                }
                " "
            }
            span(
                .class("upload-status-inline js-dataset-status"), .role("status"),
                .custom(name: "aria-live", value: "polite")
            ) {}
            " "
            span(attributes: [.class("chip-row js-dataset-estimates")] + hiddenUnlessDataset) {
                " "
                span(.class("chip js-dataset-similarity"), .hidden) {}
                " "
                span(.class("chip js-dataset-drift"), .hidden) {}
                " "
            }
        }
    }
}

/// An attached dataset's name cell: the course library's dataset icon, its
/// name linked to its library page, and the version the file pins. The link
/// opens a new tab, because the workbench shows this table over a live kernel.
private struct DatasetNameCell: HTML {
    let attachment: SupportFileLibraryState.Attachment

    var body: some HTML {
        Icon("i-list")
        " "
        NewTabLink(href: InstructorDatasetDetail.href(slug: attachment.slug), text: attachment.name)
        " "
        span(.class("chip")) { "v\(attachment.version)" }
    }
}

/// An attached dataset's actions. Its file is the library's, so there is no
/// plain delete: the delete door refuses an attached file, and Remove detaches
/// it and removes the file in one step.
private struct AttachedDatasetActions: HTML {
    let filename: String
    let attachment: SupportFileLibraryState.Attachment

    var body: some HTML {
        if let newer = attachment.newerVersion {
            button(
                .class("btn action-btn js-library-update"), .type(.button), .data("filename", value: filename)
            ) { "Update to v\(newer)" }
            " "
        }
        button(
            .class("btn action-btn js-library-detach"), .type(.button), .data("filename", value: filename),
            .title("Keep the file and its per-student sample as a support file")
        ) { "Detach" }
        " "
        button(
            .class("btn action-btn action-danger js-library-remove"), .type(.button),
            .data("filename", value: filename)
        ) { "Remove" }
    }
}

/// The course library line under a support file: the row scope of an attached
/// dataset, or the move into the library for a CSV that is not attached.
/// Public/support-files.js sends each action.
private struct SupportFileLibraryControl: HTML {
    let filename: String
    let library: SupportFileLibraryState

    var body: some HTML {
        div(.class("dataset-control")) {
            if let attachment = library.attachment {
                label(.class("dataset-toggle")) {
                    input(
                        attributes: [
                            .type(.checkbox), .class("js-library-scope"), .data("filename", value: filename),
                        ] + (attachment.isCourseScoped ? [.checked] : []))
                    " Course-wide rows"
                }
            } else {
                button(
                    .class("btn action-btn js-library-promote"), .type(.button), .data("filename", value: filename)
                ) { "Move to course library" }
            }
        }
    }
}
