import Fluent

struct CreateRunnerSnapshots: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(RunnerSnapshot.schema)
            .id()
            .field("runner_id", .string, .required)
            .field("recorded_at", .datetime, .required)
            .field("active_jobs", .int, .required)
            .field("max_jobs", .int, .required)
            .field("available_capacity", .int, .required)
            .field("hostname", .string)
            .field("runner_version", .string)
            .field("last_poll_at", .datetime)
            .field("last_heartbeat_at", .datetime)
            .field("server_assigned_job_count_since_start", .int)
            .create()

    }

    func revert(on database: Database) async throws {
        try await database.schema(RunnerSnapshot.schema)
            .delete()
    }
}
