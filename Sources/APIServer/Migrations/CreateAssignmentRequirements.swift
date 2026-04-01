import Fluent

struct CreateAssignmentRequirements: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AssignmentRequirement.schema)
            .id()
            .field(
                "assignment_id",
                .uuid,
                .required,
                .references("assignments", "id", onDelete: .cascade)
            )
            .field("required_platform", .string)
            .field("required_architecture", .string)
            .field("required_languages_json", .string, .required)
            .field("required_capabilities_json", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "assignment_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AssignmentRequirement.schema).delete()
    }
}
