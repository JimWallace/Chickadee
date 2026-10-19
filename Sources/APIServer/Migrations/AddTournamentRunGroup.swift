// APIServer/Migrations/AddTournamentRunGroup.swift
//
// The lab group of a tournament run (docs/lab-groups.md, slice 3d): for an
// activity that runs once per group, each group plays its own run, entered
// by the students who joined its session. Optional: nil is a run of the
// whole class, which is every run made before the column.

import Fluent

struct AddTournamentRunGroup: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APITournamentRun.schema)
            .field("group_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APITournamentRun.schema)
            .deleteField("group_id")
            .update()
    }
}
