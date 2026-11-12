// APIServer/Migrations/AddWardrobeUnlockSource.swift
//
// A wardrobe unlock records what granted it (docs/achievement-rewards.md,
// decision 4, slice S2):
//
// - `wardrobe_unlocks.source`: nullable text. `achievement:<level>:<owner>:<id>`
//   for an item an achievement granted; null for an item a built-in rule
//   earned or a student found, which is every row that exists before this.
// - `wardrobe_unlocks.label`: nullable text, the achievement's name when it
//   granted the item. The account page reads it for "how you earned it". It
//   is a label, not a foreign key, so the item keeps its text after the
//   course or the assignment that granted it is gone.
//
// Schema only: no row changes. The old color of a blue-green deploy does not
// map either column, and its inserts leave both null, which reads as a rule
// item.

import Fluent

struct AddWardrobeUnlockSource: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIWardrobeUnlock.schema)
            .field("source", .string)
            .field("label", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIWardrobeUnlock.schema)
            .deleteField("label")
            .deleteField("source")
            .update()
    }
}
