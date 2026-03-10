// APIServer/Migrations/CreateUsers.swift

import Fluent
import SQLKit

struct CreateUsers: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .id()
            .field("username",         .string,   .required)
            .unique(on: "username")
            .field("password_hash",    .string,   .required)
            .field("role",             .string,   .required)
            // Profile fields (formerly AddUserProfileFields)
            .field("preferred_name",   .string)
            .field("user_id",          .string)
            .field("student_id",       .string)
            // SSO fields (formerly AddUserSSOFields)
            .field("auth_provider",    .string)
            .field("external_subject", .string)
            .field("email",            .string)
            .field("display_name",     .string)
            .field("last_login_at",    .datetime)
            .field("created_at",       .datetime)
            .create()

        // Partial unique index: one SSO identity per provider.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_users_auth_provider_external_subject
                ON users(auth_provider, external_subject)
                WHERE auth_provider IS NOT NULL AND external_subject IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "DROP INDEX IF EXISTS idx_users_auth_provider_external_subject"
            ).run()
        }
        try await database.schema("users").delete()
    }
}
