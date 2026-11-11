// APIServer/Utilities/AuthoringChecks/AuthoringSnapshot.swift
//
// Everything the authoring checks read, loaded once per `check_assignment` call
// (#2747). The checks see this value and nothing else, so a test builds one by
// hand and needs no database.
//
// The MCP loader (`AuthoringSnapshot+Loading.swift`) fills it: the manifest,
// the stored validation runs, read through `MCPStudentDataBoundary` so that no
// student row is reached, the placeholder names in use, and one expression
// evaluation per validation-variant seed.

import Core

struct AuthoringSnapshot: Sendable {
    /// One run of the multi-variant validation batch (`ValidationVariant`).
    struct VariantRun: Sendable {
        let variantIndex: Int
        let seedHex: String
        /// `ValidationVariant.Status`: pending, passed or failed.
        let status: String
        /// The run's outcomes, or nil when it has none yet or they could not
        /// be read.
        let run: TestOutcomeCollection?
    }

    /// The per-student expressions evaluated for one seed.
    struct SeedEvaluation: Sendable {
        let seedHex: String
        /// Nil when every expression evaluated.
        let error: String?
    }

    let manifest: TestProperties
    /// The assignment's declared type, so the type rules are reported with
    /// the manifest rules (docs/assignment-types.md). Nil checks the manifest
    /// alone.
    var assignmentType: AssignmentType?
    /// The latest validation run of the reference solution, or nil before one.
    var solutionRun: TestOutcomeCollection?
    /// The current variant batch, in variant order. Empty when the manifest
    /// does not vary by student.
    var variants: [VariantRun] = []
    /// The latest starter run, or nil before one.
    var starterRun: TestOutcomeCollection?
    /// Every per-student input name the content refers to: `{{name}}` in the
    /// starter notebook and `$name` refs in pattern-family cases.
    var placeholderNames: Set<String> = []
    /// The source of each starter-notebook cell, in order: the code cell's
    /// source, or nil for any other kind, so an index is the cell's own.
    var notebookCodeCells: [String?] = []
    /// The setup zip's entries, or nil when they could not be listed. The
    /// checks derive what a student receives with `StudentWorkspaceFiles`.
    var setupZipEntries: [String]?
    /// One evaluation per validation-variant seed. Empty when the manifest
    /// declares no expressions.
    var seedEvaluations: [SeedEvaluation] = []
}
