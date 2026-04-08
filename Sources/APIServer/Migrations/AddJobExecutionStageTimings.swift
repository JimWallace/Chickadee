import Fluent

struct AddJobExecutionStageTimings: AsyncMigration {
    func prepare(on database: Database) async throws {
        for field in fields {
            try await database.schema(JobExecutionMetric.schema)
                .field(FieldKey(stringLiteral: field), .int)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for field in fields {
            try await database.schema(JobExecutionMetric.schema)
                .deleteField(FieldKey(stringLiteral: field))
                .update()
        }
    }

    private var fields: [String] {
        [
            "workdir_setup_ms",
            "submission_dir_setup_ms",
            "submission_download_ms",
            "test_setup_acquire_ms",
            "submission_unpack_ms",
            "starter_cleanup_ms",
            "submission_prepare_ms",
            "make_step_ms",
            "runtime_helper_setup_ms",
            "test_execution_ms",
        ]
    }
}
