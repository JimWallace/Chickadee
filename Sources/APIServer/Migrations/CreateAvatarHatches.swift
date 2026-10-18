// APIServer/Migrations/CreateAvatarHatches.swift
//
// `avatar_hatches`: one row per "Hatch a new bird" (APIAvatarHatch). The rows
// go with the user. `slot` numbers a user's hatches in one term from 1, and
// the unique index makes a fourth hatch, or two at once, fail in the
// database too.

import Fluent

struct CreateAvatarHatches: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIAvatarHatch.schema)
            .id()
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("term_key", .string, .required)
            .field("slot", .int, .required)
            .field("created_at", .datetime)
            // Folded from AddAvatarHatchSpecies (fifth round): the species the
            // hatch came from and went to (#2593). nil = not recorded.
            .field("from_species", .string)
            .field("species", .string)
            .unique(on: "user_id", "term_key", "slot")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIAvatarHatch.schema).delete()
    }
}
