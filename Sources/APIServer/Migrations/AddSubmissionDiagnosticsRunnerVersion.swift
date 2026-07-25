// APIServer/Migrations/AddSubmissionDiagnosticsRunnerVersion.swift
//
// Adds the `runner_version` column to submission_diagnostics: the version the
// runner advertised when it claimed the job.
//
// `runner_id` already records *which* runner ran a submission, but the runner's
// version was only ever live heartbeat state on the runner dashboard — so the
// version for a historical job could only be found by joining to what that
// runner is running *now*. During a rolling upgrade that join returns the wrong
// answer, which is exactly when the question gets asked: a suite that depends on
// a newer runner build fails on a lagging runner and passes on a current one,
// and without the recorded version the failure reads as a content bug rather
// than version skew.
//
// Shipped as a standalone Add* migration (not folded into
// CreateSubmissionDiagnostics) because production databases have already applied
// that migration and would never pick the column up from a model change. Fresh
// deploys run CreateSubmissionDiagnostics then this; existing prod runs only
// this. Nullable, so rows written before this shipped stay valid and simply
// report no version.

import Fluent

struct AddSubmissionDiagnosticsRunnerVersion: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submission_diagnostics").field("runner_version", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submission_diagnostics").deleteField("runner_version").update()
    }
}
