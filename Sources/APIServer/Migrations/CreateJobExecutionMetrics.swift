import Fluent

struct CreateJobExecutionMetrics: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(JobExecutionMetric.schema)
            .id()
            .field(
                "submission_id",
                .string,
                .required,
                .references("submissions", "id", onDelete: .cascade)
            )
            .field("job_id", .string, .required)
            .field(
                "test_setup_id",
                .string,
                .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field("course_id", .uuid, .references("courses", "id", onDelete: .setNull))
            .field("assignment_id", .uuid, .references("assignments", "id", onDelete: .setNull))
            .field("user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("runner_id", .string)
            .field("kind", .string, .required)
            .field("attempt_number", .int)
            .field("enqueued_at", .datetime)
            .field("assigned_at", .datetime)
            .field("started_at", .datetime)
            .field("completed_at", .datetime)
            .field("queue_wait_ms", .int)
            .field("execution_ms", .int)
            .field("total_processing_ms", .int)
            .field("final_status", .string)
            .field("tests_passed", .int)
            .field("tests_failed", .int)
            .field("tests_errored", .int)
            .field("tests_timed_out", .int)
            .field("skipped_count", .int)
            // Folded from AddJobExecutionStageTimings — per-stage breakdown
            // of the worker's job runtime, in milliseconds.
            .field("workdir_setup_ms", .int)
            .field("submission_dir_setup_ms", .int)
            .field("submission_download_ms", .int)
            .field("test_setup_acquire_ms", .int)
            .field("submission_unpack_ms", .int)
            .field("starter_cleanup_ms", .int)
            .field("submission_prepare_ms", .int)
            .field("make_step_ms", .int)
            .field("runtime_helper_setup_ms", .int)
            .field("test_execution_ms", .int)
            // Folded from AddJobDiskUsageMetrics.
            .field("free_disk_mb_at_start", .int)
            .field("free_disk_mb_at_end", .int)
            .field("workdir_peak_bytes", .int64)
            // Folded from AddJobExecutionCacheHit.
            .field("test_setup_cache_hit", .bool)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "submission_id")
            .create()

    }

    func revert(on database: Database) async throws {
        try await database.schema(JobExecutionMetric.schema)
            .delete()
    }
}
