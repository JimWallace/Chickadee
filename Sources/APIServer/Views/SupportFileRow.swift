// APIServer/Views/SupportFileRow.swift
//
// One support file in the Files table of the assignment editors: a data
// fixture (CSV, JSON, ...) bundled with the assignment, with its per-student
// dataset control (docs/datasets.md). The create page and the edit body render
// the same markup, and Public/support-files.js drives both.

import Elementary

struct SupportFileRow: HTML {
    let file: EditableSuiteRow

    var body: some HTML {
        tr(.data("support-file", value: file.name)) {
            td { strong { "Support file" } }
            td {
                a(.href(file.url)) { code { file.name } }
                datasetControl
                if let library = file.library {
                    SupportFileLibraryControl(filename: file.name, library: library)
                }
            }
            td(.class("time")) {
                // The delete door refuses an attached file, so its Remove
                // detaches it and removes the file in one step.
                button(
                    .class(
                        "btn action-btn action-danger "
                            + (isAttached ? "js-library-remove" : "js-support-file-delete-btn")),
                    .type(.button), .data("filename", value: file.name)
                ) { "Remove" }
            }
        }
    }

    private var isAttached: Bool { file.library?.attachment != nil }

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
                " Per-student sample"
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
                " parts, one per student — edit it with set_dataset."
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

/// The course library line under a support file: where an attached file comes
/// from, with update, scope and detach, or the move into the library for a
/// CSV that is not attached. Public/support-files.js sends each action.
private struct SupportFileLibraryControl: HTML {
    let filename: String
    let library: SupportFileLibraryState

    var body: some HTML {
        div(.class("dataset-control")) {
            if let attachment = library.attachment {
                span { "From \(attachment.sourceText)" }
                if let newer = attachment.newerVersion {
                    button(
                        .class("btn action-btn js-library-update"), .type(.button),
                        .data("filename", value: filename)
                    ) { "Update to v\(newer)" }
                }
                label(.class("dataset-toggle")) {
                    input(
                        attributes: [
                            .type(.checkbox), .class("js-library-scope"), .data("filename", value: filename),
                        ] + (attachment.isCourseScoped ? [.checked] : []))
                    " Course-wide rows"
                }
                button(
                    .class("btn action-btn js-library-detach"), .type(.button), .data("filename", value: filename)
                ) { "Detach" }
                span(.class("dataset-note")) { "Detach keeps the file and its per-student sample." }
            } else {
                button(
                    .class("btn action-btn js-library-promote"), .type(.button), .data("filename", value: filename)
                ) { "Move to course library" }
            }
        }
    }
}
