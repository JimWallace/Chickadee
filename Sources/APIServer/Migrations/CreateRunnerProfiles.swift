import Fluent

struct CreateRunnerProfiles: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(RunnerProfile.schema)
            .id()
            .field("runner_id", .string, .required)
            .field("display_name", .string)
            .field("platform", .string, .required)
            .field("architecture", .string, .required)
            .field("language_versions_json", .string, .required)
            .field("capabilities_json", .string, .required)
            .field("profile_hash", .string)
            .field("last_registered_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .field("is_active", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "runner_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(RunnerProfile.schema).delete()
    }
}
