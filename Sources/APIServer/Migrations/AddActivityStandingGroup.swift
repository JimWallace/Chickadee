// APIServer/Migrations/AddActivityStandingGroup.swift
//
// The lab group of a round robin's standings row (docs/lab-groups.md, slice
// 3c): the group of the session the row's submission was made in, for an
// activity that runs once per group. Optional: nil is course-wide, which is
// every row made before the column.

import Fluent

struct AddActivityStandingGroup: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIActivityStanding.schema)
            .field("group_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIActivityStanding.schema)
            .deleteField("group_id")
            .update()
    }
}
