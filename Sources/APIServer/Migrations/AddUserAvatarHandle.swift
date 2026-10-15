// APIServer/Migrations/AddUserAvatarHandle.swift
//
// `users.avatar_handle`: the bird's handle, its name in every course, unique
// across the deployment (docs/student-avatars.md §3). `users.avatar_previous_handle`:
// the handle of the bird before the last hatch. Both optional: a handle is
// drawn on first need, and `MoveHandlesToBirds` fills the existing ones.

import Fluent
import SQLKit

struct AddUserAvatarHandle: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        // One column per update: SQLite adds one column per ALTER TABLE.
        try await database.schema(APIUser.schema).field("avatar_handle", .string).update()
        try await database.schema(APIUser.schema).field("avatar_previous_handle", .string).update()
        // Partial, so the many users with no handle yet do not collide.
        if let sql = database as? (any SQLDatabase) {
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
        }
        try await database.schema(APIUser.schema).deleteField("avatar_previous_handle").update()
        try await database.schema(APIUser.schema).deleteField("avatar_handle").update()
    }
}
