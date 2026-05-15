import Fluent

struct CreateSubmissionDiagnostics: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submission_diagnostics")
            .field(
                "submission_id",
                .string,
                .identifier(auto: false),
                .references("submissions", "id", onDelete: .cascade)
            )
            .field(
                "test_setup_id",
                .string,
                .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field("course_id", .uuid, .references("courses", "id", onDelete: .setNull))
            .field("assignment_id", .uuid, .references("assignments", "id", onDelete: .setNull))
            .field("kind", .string, .required)
            .field("submitted_at", .datetime)
            .field("assigned_at", .datetime)
            .field("started_at", .datetime)
            .field("finished_at", .datetime)
            .field("queue_wait_ms", .int)
            .field("execution_ms", .int)
            .field("turnaround_ms", .int)
            .field("final_status", .string)
            .field("runner_id", .string)
            .field("timed_out", .bool)
            .field("exit_code", .int)
            .field("termination_reason", .string)
            .field("peak_rss_bytes", .int)
            .field("wall_clock_ms", .int)
            .field("child_process_count", .int)
            .field("stdout_bytes", .int)
            .field("stderr_bytes", .int)
            // Folded from AddJobDiskUsageMetrics.  Mirrors the same disk-usage
            // fields on job_execution_metrics; submission_diagnostics is the
            // 1:1 legacy mirror kept for cross-runner debugging.
            .field("free_disk_mb_at_start", .int)
            .field("free_disk_mb_at_end", .int)
            .field("workdir_peak_bytes", .int64)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submission_diagnostics").delete()
    }
}
