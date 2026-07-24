// Core/Job.swift
//
// Shared job descriptor returned by POST /api/v1/worker/request.
// Defined in Core so both APIServer and Worker can reference it without
// introducing a cross-target dependency between the two executables.

import Foundation

/// A unit of work handed to a worker after it wins a polling request.
public struct Job: Codable, Sendable {
    public let submissionID: String
    public let testSetupID: String
    /// How many times this student has submitted against this test setup (1-based).
    public let attemptNumber: Int
    /// URL the worker should GET to download the submission file.
    public let submissionURL: URL
    /// URL the worker should GET to download the test-setup zip.
    public let testSetupURL: URL
    /// Parsed manifest — avoids a second round-trip to fetch it separately.
    public let manifest: TestProperties
    /// Non-nil when the submission is a raw file (not a zip).
    /// The worker copies it into the test directory under this filename.
    public let submissionFilename: String?

    /// Per-(student, assignment) random hex seed. Surfaced to grading
    /// subprocesses via `CHICKADEE_ASSIGNMENT_SEED`. Nil when the submission
    /// has no associated student (e.g. very old pre-Phase-6 submissions) or
    /// the server cannot resolve the student's assignment — in which case the
    /// runner skips env-var injection and grading proceeds without a seed.
    public let assignmentSeed: String?

    /// Per-student personalization inputs, resolved server-side for this
    /// submission's `assignmentSeed` by evaluating the manifest's global +
    /// section `=` expressions. Maps each input name to its evaluated value
    /// rendered as a Python literal (`repr(value)` — the same form
    /// `PersonalizationEvaluator` emits for notebook substitution). The worker
    /// materializes these into `_ck_inputs.py` in the grading workspace so
    /// pattern-family scripts that reference per-student args / expected can
    /// load them. Nil when the assignment declares no expressions or no seed
    /// is available — generated scripts that need a value then fail closed
    /// with a clear message.
    public let personalizedInputs: [String: String]?

    /// Per-student dataset files, resolved server-side for this submission's
    /// `assignmentSeed` (Phase 1 datasets — see docs/datasets.md). Maps each
    /// dataset's delivered filename to its sliced contents (a deterministic
    /// per-student slice of the instructor's source pool, produced by
    /// `DatasetMaterializer`). The worker writes each into the grading
    /// workspace, overwriting the source pool copied from the cached test-setup
    /// so student scripts read only their slice. Nil when the assignment
    /// declares no datasets or no seed is available — grading then proceeds
    /// against the file as shipped. Same delivery shape as `personalizedInputs`:
    /// the server resolves the bytes; the worker only writes them.
    public let personalizedFiles: [String: String]?

    /// The assignment's language (`.python` | `.r`), resolved server-side from
    /// the manifest / notebook kernel. Selects how per-student inputs are
    /// rendered + delivered (`_ck_inputs.py` vs `_ck_inputs.R`) and which
    /// interpreter evaluated the expressions. Optional for wire back-compat: a
    /// payload from an older server decodes as nil, which callers treat as
    /// `.python` — so existing Python jobs are byte-for-byte unchanged.
    public let language: AssignmentLanguage?

    public init(
        submissionID: String,
        testSetupID: String,
        attemptNumber: Int,
        submissionURL: URL,
        testSetupURL: URL,
        manifest: TestProperties,
        submissionFilename: String? = nil,
        assignmentSeed: String? = nil,
        personalizedInputs: [String: String]? = nil,
        personalizedFiles: [String: String]? = nil,
        language: AssignmentLanguage? = nil
    ) {
        self.submissionID = submissionID
        self.testSetupID = testSetupID
        self.attemptNumber = attemptNumber
        self.submissionURL = submissionURL
        self.testSetupURL = testSetupURL
        self.manifest = manifest
        self.submissionFilename = submissionFilename
        self.assignmentSeed = assignmentSeed
        self.personalizedInputs = personalizedInputs
        self.personalizedFiles = personalizedFiles
        self.language = language
    }
}
