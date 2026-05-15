import Fluent

/// Adds `test_setup_cache_hit` to `job_execution_metrics` so the admin
/// runner detail page can report each runner's TestSetupCache hit rate
/// per the audit follow-up in #492.  Nullable boolean; existing rows
/// stay nil, and older runners that don't yet send `testSetupCacheHit`
/// continue to record nil.
struct AddJobExecutionCacheHit: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(JobExecutionMetric.schema)
            .field("test_setup_cache_hit", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(JobExecutionMetric.schema)
            .deleteField("test_setup_cache_hit")
            .update()
    }
}
