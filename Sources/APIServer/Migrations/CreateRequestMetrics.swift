import Fluent

struct CreateRequestMetrics: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("request_metrics")
            .id()
            .field("method", .string, .required)
            .field("path", .string, .required)
            .field("request_kind", .string)
            .field("status_code", .int, .required)
            .field("started_at", .datetime, .required)
            .field("finished_at", .datetime, .required)
            .field("duration_ms", .int, .required)
            .field("submission_id", .string, .references("submissions", "id", onDelete: .setNull))
            .field("worker_id", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("request_metrics").delete()
    }
}
