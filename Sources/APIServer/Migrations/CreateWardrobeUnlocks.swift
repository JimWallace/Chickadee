// APIServer/Migrations/CreateWardrobeUnlocks.swift
//
// `wardrobe_unlocks`: one row per wardrobe item a student has earned
// (APIWardrobeUnlock, #2592). The rows go with the user. The unique index
// stores an item once per user when two requests grant it at once.

import Fluent

struct CreateWardrobeUnlocks: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIWardrobeUnlock.schema)
            .id()
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("item", .string, .required)
            .field("unlocked_at", .datetime)
            .unique(on: "user_id", "item")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIWardrobeUnlock.schema).delete()
    }
}
