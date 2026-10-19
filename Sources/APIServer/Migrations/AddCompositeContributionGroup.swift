// APIServer/Migrations/AddCompositeContributionGroup.swift
//
// The lab group of a class composite contribution (docs/lab-groups.md, slice
// 4): the group whose image the student's slot is in. Optional: nil is the
// whole class's image, which is every row made before the column.

import Fluent

struct AddCompositeContributionGroup: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APICompositeContribution.schema)
            .field("group_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APICompositeContribution.schema)
            .deleteField("group_id")
            .update()
    }
}
