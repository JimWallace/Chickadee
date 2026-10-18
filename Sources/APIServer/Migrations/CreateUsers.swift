// APIServer/Migrations/CreateUsers.swift

import Fluent
import SQLKit

struct CreateUsers: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .id()
            .field("username", .string, .required)
            .unique(on: "username")
            .field("password_hash", .string, .required)
            .field("role", .string, .required)
            // Profile fields (formerly AddUserProfileFields)
            .field("preferred_name", .string)
            .field("user_id", .string)
            .field("student_id", .string)
            // SSO fields (formerly AddUserSSOFields)
            .field("auth_provider", .string)
            .field("external_subject", .string)
            .field("email", .string)
            .field("display_name", .string)
            .field("last_login_at", .datetime)
            // Folded from AddUserLastSeenAt.
            .field("last_seen_at", .datetime)
            // Folded from AddBrightSpaceSyncFields.
            .field("brightspace_user_id", .string)
            // Folded from AddUrlTokenToUsers (#556): the opaque per-user token
            // that replaced `:username` URL segments. Nullable column — the
            // model invariant (every row carries a token) is enforced by the
            // init default; the historical migration's backfill of pre-token
            // rows is a no-op on an empty fresh table and was dropped.
            .field("url_token", .string)
            // Folded from AddAvatarIdentity (fourth round, #1806): the
            // generated avatar's slot choices, as JSON. Nullable on purpose:
            // it is materialized the first time an avatar is needed
            // (docs/student-avatars.md).
            .field("avatar_spec", .string)
            // Folded from AddUserAvatarPreviousSpec (fifth round): the bird
            // before the last hatch. nil = no previous bird.
            .field("avatar_previous_spec", .string)
            // Folded from AddUserAvatarHandle (fifth round): the bird's handle,
            // unique across the deployment (docs/student-avatars.md §3), and
            // the handle of the bird before the last hatch. nil until drawn.
            .field("avatar_handle", .string)
            .field("avatar_previous_handle", .string)
            .field("created_at", .datetime)
            .create()

        // Partial unique index: one SSO identity per provider.
        if let sql = database as? (any SQLDatabase) {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_users_auth_provider_external_subject
                ON users(auth_provider, external_subject)
                WHERE auth_provider IS NOT NULL AND external_subject IS NOT NULL
                """
            ).run()
            // Folded from AddUrlTokenToUsers: uniqueness for the URL tokens.
            // Partial so a NULL (never expected in practice) can't collide.
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_users_url_token
                ON users(url_token)
                WHERE url_token IS NOT NULL
                """
            ).run()
            // Folded from AddUserAvatarHandle. Partial, so the many users with
            // no handle yet do not collide.
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_users_avatar_handle
                ON users(avatar_handle)
                WHERE avatar_handle IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? (any SQLDatabase) {
            try await sql.raw("DROP INDEX IF EXISTS idx_users_avatar_handle").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_users_url_token").run()
            try await sql.raw(
                "DROP INDEX IF EXISTS idx_users_auth_provider_external_subject"
            ).run()
        }
        try await database.schema("users").delete()
    }
}
