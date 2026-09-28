// APIServer/Migrations/CreateClassCoverageRuns.swift

import Fluent

struct CreateClassCoverageRuns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("class_coverage_runs")
            .id()
            .field("test_setup_id", .string, .required)
            .field("submission_id", .string, .required)
            .field("contributors", .string, .required)
            .field("coverage", .double)
            .field("created_at", .datetime, .required)
            .field("completed_at", .datetime)
            // One row per corpus submission. The ingest path completes a run by
            // its submission id, so a replayed report updates the same row
            // rather than opening a second one.
            .unique(on: "submission_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("class_coverage_runs").delete()
    }
}
