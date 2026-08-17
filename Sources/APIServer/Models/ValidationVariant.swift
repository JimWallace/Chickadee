// APIServer/Models/ValidationVariant.swift
//
// One synthetic per-student variant of an assignment's validation run.
//
// A validation submission grades the reference solution against the enqueuing
// instructor's own seed — one variant of a per-student assignment.  When the
// manifest varies by seed (`TestProperties.variesPerStudent`: a per-student
// `=` expression or a dataset slice), that single run proves nothing about
// the material other students receive: a solution that assumes a column is
// never blank validates green and then fails for the student whose seed
// blanked it.  So every validation enqueue also runs the solution against
// `validationVariantCount` derived preflight seeds — the same seeds the
// Files-panel estimates sample — and each of those runs is recorded here.
//
// Rows are the CURRENT batch only: a new enqueue deletes the setup's rows and
// writes fresh ones, mirroring how `assignment.validationSubmissionID` always
// points at the latest primary run.  The underlying variant submissions stay
// in `submissions` as history like any other validation; `submission_id` is
// `onDelete: .setNull` so retention pruning a submission leaves the recorded
// verdict standing.
//
// Keyed by `test_setup_id` (not assignment id) because the draft flow
// enqueues validation before the assignment row exists — the same reason
// `submissions` itself is setup-keyed.

import Fluent
import Vapor

final class ValidationVariant: Model, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "validation_variants"

    /// The per-run verdict vocabulary, mirroring the primary's
    /// `validationStatus` subset a run can reach ("no-runner" is decided
    /// before any run exists, so it never lands on a variant row).
    enum Status {
        static let pending = "pending"
        static let passed = "passed"
        static let failed = "failed"
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// 0-based position in the batch; the seed is
    /// `DatasetDiagnostics.preflightSeed(variantIndex)`.
    @Field(key: "variant_index")
    var variantIndex: Int

    /// The 64-hex seed this variant graded against — stored rather than
    /// re-derived so the row still says what actually ran if the derivation
    /// ever changes.
    @Field(key: "seed_hex")
    var seedHex: String

    /// The `kind == .validation` submission that carried this variant's run.
    @OptionalField(key: "submission_id")
    var submissionID: String?

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(testSetupID: String, variantIndex: Int, seedHex: String, submissionID: String?) {
        self.testSetupID = testSetupID
        self.variantIndex = variantIndex
        self.seedHex = seedHex
        self.submissionID = submissionID
        self.status = Status.pending
    }
}
