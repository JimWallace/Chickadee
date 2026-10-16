// APIServer/Migrations/AddAvatarHatchSpecies.swift
//
// `avatar_hatches.from_species` and `avatar_hatches.species`: the species a
// hatch came from and went to (#2593). They were for the life list, which
// the account page no longer shows; they stay as the record of each hatch,
// and the data export carries them. Optional: a row made before the columns
// has neither, and no species is guessed for it.

import Fluent

struct AddAvatarHatchSpecies: ChickadeeMigration {
    // One column per statement: SQLite adds or drops one column per ALTER.
    func prepare(on database: any Database) async throws {
        try await database.schema(APIAvatarHatch.schema).field("from_species", .string).update()
        try await database.schema(APIAvatarHatch.schema).field("species", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIAvatarHatch.schema).deleteField("species").update()
        try await database.schema(APIAvatarHatch.schema).deleteField("from_species").update()
    }
}
