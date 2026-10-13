// APIServer/Views/SupportFileRow.swift
//
// One support file in the Files table of the assignment editors: a data
// fixture (CSV, JSON, ...) bundled with the assignment, with its per-student
// dataset control (docs/datasets.md). The create page and the edit body render
// the same markup, and Public/support-files.js drives both.
//
// Keep in step with the support-file rows in `_assignment-edit-body.leaf`
// while both exist.

import Elementary

struct SupportFileRow: HTML {
    let file: EditableSuiteRow

    var body: some HTML {
        tr(.data("support-file", value: file.name)) {
            td { strong { "Support file" } }
            td {
                a(.href(file.url)) { code { file.name } }
                datasetControl
            }
            td(.class("time")) {
                button(
                    .class("btn action-btn action-danger js-support-file-delete-btn"), .type(.button),
                    .data("filename", value: file.name)
                ) { "Remove" }
            }
        }
    }

    /// `hidden` on the fields that only mean something for a dataset.
    private var hiddenUnlessDataset: [MarkupAttribute<HTMLTag.span>] {
        file.isDataset ? [] : [.hidden]
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
                input(attributes: [.type(.checkbox), .class("js-dataset-toggle")] + (file.isDataset ? [.checked] : []))
                " Per-student sample"
            }
            " "
            span(attributes: [.class("dataset-size-field js-dataset-size-field")] + hiddenUnlessDataset) {
                " "
                input(
                    .type(.number), .min(1), .step(1), .class("form-input input-sm dataset-size js-dataset-size"),
                    .value(file.datasetSampleSizeText), .ariaLabel("Rows per student from \(file.name)"))
                " rows per student"
            }
            " "
            span(attributes: [.class("dataset-size-field js-dataset-stratum-field")] + hiddenUnlessDataset) {
                "balanced across "
                input(
                    .type(.text), .class("form-input input-sm dataset-stratum js-dataset-stratum"),
                    .value(file.datasetStratumColumnOrEmpty), .placeholder("column (optional)"),
                    .ariaLabel("Column to balance the sample of \(file.name) across"))
                " "
            }
            " "
            span(attributes: [.class("dataset-size-field js-dataset-blank-field")] + hiddenUnlessDataset) {
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
            if !file.datasetTransformsEditable {
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
