// APIServer/Migrations/AddSubmissionMaterialization.swift
//
// Adds the optional `materialization_json` column to the submissions table:
// the cached, once-resolved personalization for a validation submission (see
// `SubmissionMaterialization`). It lets the worker poll + download paths read
// pre-resolved values instead of running the personalization evaluator on a
// hot path the runner times out against.
//
// Standalone Add* migration because production has already applied
// CreateSubmissions without this column and would never pick it up from a body
// change. Fresh deploys run CreateSubmissions then this; existing prod runs
// only this one. Additive + nullable, so existing rows are unaffected.

import Fluent

struct AddSubmissionMaterialization: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("materialization_json", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions")
            .deleteField("materialization_json")
            .update()
    }
}
