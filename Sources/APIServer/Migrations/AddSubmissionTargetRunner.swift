// APIServer/Migrations/AddSubmissionTargetRunner.swift
//
// `submissions.target_runner_id`: the runner that a staff-requested validation
// run asks for (MCP `run_validation`). Optional: every other row, and every row
// made before the column, has no target, and any runner may claim it.

import Fluent

struct AddSubmissionTargetRunner: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APISubmission.schema)
            .field("target_runner_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APISubmission.schema)
            .deleteField("target_runner_id")
            .update()
    }
}
