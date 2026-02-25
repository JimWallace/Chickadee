import Fluent
import SQLKit

struct AddUserSSOFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("auth_provider", .string)
            .update()
        try await database.schema("users")
            .field("external_subject", .string)
            .update()
        try await database.schema("users")
            .field("email", .string)
            .update()
        try await database.schema("users")
            .field("display_name", .string)
            .update()
        try await database.schema("users")
            .field("last_login_at", .datetime)
            .update()

        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_users_auth_provider_external_subject
            ON users(auth_provider, external_subject)
            WHERE auth_provider IS NOT NULL AND external_subject IS NOT NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            try await database.schema("users")
                .deleteField("last_login_at")
                .update()
            try await database.schema("users")
                .deleteField("display_name")
                .update()
            try await database.schema("users")
                .deleteField("email")
                .update()
            try await database.schema("users")
                .deleteField("external_subject")
                .update()
            try await database.schema("users")
                .deleteField("auth_provider")
                .update()
            return
        }

        try await sql.raw(
            "DROP INDEX IF EXISTS idx_users_auth_provider_external_subject"
        ).run()

        try await database.schema("users")
            .deleteField("last_login_at")
            .update()
        try await database.schema("users")
            .deleteField("display_name")
            .update()
        try await database.schema("users")
            .deleteField("email")
            .update()
        try await database.schema("users")
            .deleteField("external_subject")
            .update()
        try await database.schema("users")
            .deleteField("auth_provider")
            .update()
    }
}
