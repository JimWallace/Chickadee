// APIServer/Views/FamilyEditorBody.swift
//
// The pattern-family editor body, shared by the Create Assignment page and the
// assignment edit body. Public/pattern-family-editor.js drives it on both, and
// relocates this hidden body into the unified Test Editor modal when a family
// is opened. The Variables table has four columns (valid / name / value /
// action) to match the rows that script builds.
//
// Keep in step with `_family-editor-body.leaf` while both exist. The coverage
// tests read the kind and failure-detail options from that file.

import Elementary

struct FamilyEditorBody: HTML {
    var body: some HTML {
        div(
            .id("family-editor-body"), .class("family-editor-body"), .hidden,
            .custom(name: "style", value: "display:none")
        ) {
            div(.class("family-editor-grid")) {
                label(.id("family-function-label"), .class("field-stack")) {
                    "Function "
                    select(.class("form-input editor-input"), .id("family-function-select")) {
                        option(.value("")) { "— Scanning solution notebook… —" }
                    }
                    " "
                    span(.id("family-function-hint"), .class("card-meta hint-xs")) {}
                    " "
                }
                " "
                label(.class("field-stack")) {
                    "Family name (shown in UI) "
                    input(
                        .type(.text), .class("form-input editor-input"), .id("family-name"),
                        .placeholder("BMI Category Boundaries"))
                    " "
                }
            }
            div(.class("family-editor-grid")) {
                label(.class("field-stack")) {
                    "Pattern kind "
                    select(.class("form-input editor-input"), .id("family-kind")) {
                        for (value, text) in Self.kinds {
                            option(.value(value)) { text }
                        }
                    }
                    " "
                }
                " "
                label(
                    .id("family-io-comparison-label"), .class("field-stack"),
                    .custom(name: "style", value: "display:none")
                ) {
                    "Output comparison "
                    select(.class("form-input editor-input"), .id("family-io-comparison")) {
                        option(.value("exact")) { "Exact (whole output, trailing whitespace ignored)" }
                        option(.value("included")) { "Contains the expected text" }
                        option(.value("regex")) { "Matches a regular expression" }
                    }
                    " "
                }
                " "
                label(
                    .id("family-tolerance-label"), .class("field-stack"), .custom(name: "style", value: "display:none")
                ) {
                    "Tolerance (max |result − expected|) "
                    input(
                        .type(.number), .class("form-input editor-input"), .id("family-default-tolerance"),
                        .step(.any), .min(0), .placeholder("1e-6"))
                    " "
                }
            }
            label(
                .id("family-reference-label"), .class("field-stack"), .custom(name: "style", value: "display:none")
            ) {
                "Reference implementation "
                span(.class("label-note")) {
                    "(required — define "
                    code { "ck_ref_<function>" }
                    " taking the same arguments; each case's expected value is whatever it returns, "
                        + "so leave the Expected column blank)"
                }
                " "
                textarea(
                    .class("form-input editor-input"), .id("family-reference-implementation"), .rows(8),
                    .custom(name: "spellcheck", value: "false"), .placeholder("def ck_ref_classify(bmi):\n    ...")
                ) {}
                " "
            }
            div(.class("family-editor-grid")) {
                label(.class("field-stack")) {
                    "Default hint "
                    span(.class("label-note")) {
                        "(optional — shown to students when a case with no hint of its own fails)"
                    }
                    " "
                    input(
                        .type(.text), .class("form-input editor-input"), .id("family-default-hint"), .value(""),
                        .placeholder("e.g. Re-check the boundary values in the spec."))
                    " "
                }
                " "
                label(.class("field-stack")) {
                    "Failure detail "
                    span(.class("label-note")) { "(staff always see everything)" }
                    " "
                    select(.class("form-input editor-input"), .id("family-default-failure-detail")) {
                        option(.value("")) { "Full (default)" }
                        option(.value("actualOnly")) { "Actual output only" }
                        option(.value("verdictOnly")) { "Verdict only" }
                    }
                    " "
                }
            }
            // The family id, function name and parameter list are derived
            // from the function dropdown selection.
            input(.type(.hidden), .id("family-id"))
            " "
            input(.type(.hidden), .id("family-function"))
            " "
            input(.type(.hidden), .id("family-params"))
            variables
            cases
            span(
                .id("family-editor-status"), .class("editor-status"), .role("status"),
                .custom(name: "aria-live", value: "polite")
            ) {}
        }
    }

    /// The Variables table. The section's shared inputs show in it as locked
    /// rows at the top, and renderReadOnlySectionVars in
    /// pattern-family-editor.js writes the section name into the label note.
    private var variables: some HTML {
        div {
            div(.class("family-subhead")) {
                strong(.class("subhead-label")) {
                    "Variables (shared across all cases) "
                    span(.id("family-section-name-label"), .class("label-note")) {}
                }
                " "
                button(.class("btn action-btn btn-sm"), .type(.button), .id("add-family-variable-btn")) {
                    "+ Add variable"
                }
            }
            table(.class("results-table table-sm"), .id("family-variables-table")) {
                thead {
                    tr {
                        th(.class("fv-valid-col"), .ariaLabel("Valid")) {}
                        th(.class("fv-name-col")) { "Name" }
                        th(.id("family-variable-value-header")) { "Value (JSON or literal)" }
                        th(.class("fv-action-col")) {}
                    }
                }
                tbody(.id("family-variables-body")) {}
            }
            p(.class("card-meta family-empty-note"), .id("family-variables-empty")) {
                "Define a name and a value (e.g. a list or a mapping) once; reference it from any arg cell by typing "
                code { "$name" }
                ".  Locked rows come from the section's shared inputs (edit in the section's Inputs table)."
            }
            ValueCueNote()
        }
    }

    /// The Cases table. One argument column per detected parameter is built
    /// between Label and Expected when the function changes.
    private var cases: some HTML {
        div {
            div(.class("family-subhead")) {
                strong(.class("subhead-label")) { "Cases" }
                " "
                button(.class("btn action-btn btn-sm"), .type(.button), .id("add-case-btn")) { "+ Add case" }
            }
            table(.class("results-table table-sm"), .id("family-cases-table")) {
                thead {
                    tr(.id("family-cases-header")) {
                        th(.class("case-num-col")) { "#" }
                        th { "Label" }
                        th { "Expected" }
                        th(.class("fv-action-col")) {}
                    }
                }
                tbody(.id("family-cases-body")) {}
            }
            p(.class("card-meta family-empty-note"), .id("family-cases-empty")) {
                "No cases yet.  Add at least one to save this family."
            }
            // Shown only for a kind that auto-compute fills; the family
            // editor script toggles it with the kind.
            p(.class("field-note field-note--muted"), .id("family-auto-compute-note"), .hidden) {
                "If an Expected cell shows a warning, read "
                a(
                    .href(
                        "https://github.com/JimWallace/Chickadee/blob/main/docs/auto-compute.md"
                            + "#when-expected-shows-a-warning"),
                    .target(.blank), .rel("noopener noreferrer")
                ) {
                    "auto-compute warnings "
                    Icon("i-external")
                    span(.class("visually-hidden")) { "(opens in a new tab)" }
                }
                "."
            }
        }
    }

    /// The Pattern kind options, in the order the editor offers them.
    private static let kinds: [(String, String)] = [
        ("boundary_equality", "Exact equality (== comparison)"),
        ("approximate_equality", "Approximate equality (float tolerance)"),
        ("variable_equality", "Variable equality (module-level variable)"),
        ("return_type_check", "Return type check (isinstance / class name)"),
        ("exception_expected", "Exception expected (function raises a specific class)"),
        ("performance_threshold", "Performance threshold (max milliseconds)"),
        ("stdout_equality", "Stdout equality (compare captured print output)"),
        ("unordered_equality", "Unordered equality (list compare, ignore order)"),
        ("differential", "Differential (compare against a reference implementation)"),
        ("program_io", "Program I/O (run the whole program with stdin, compare stdout)"),
    ]
}
