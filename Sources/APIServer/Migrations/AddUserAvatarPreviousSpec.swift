// APIServer/Migrations/AddUserAvatarPreviousSpec.swift
//
// `users.avatar_previous_spec`: the bird before the last hatch, so the student
// can go back to it until they hatch again. Set on a hatch, cleared on a go
// back. Optional: every row made before the column has no previous bird.

import Fluent

struct AddUserAvatarPreviousSpec: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIUser.schema)
            .field("avatar_previous_spec", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIUser.schema)
            .deleteField("avatar_previous_spec")
            .update()
    }
}
