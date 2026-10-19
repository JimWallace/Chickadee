// APIServer/Migrations/AddClassCoverageRunGroup.swift
//
// The lab group of a class corpus run (docs/lab-groups.md, slice 5c): for an
// activity that runs once per group, each lab's corpus is assembled from that
// lab's students and graded on its own. Optional: nil is a run of the whole
// class, which is every run made before the column. The table's only unique
// key is the submission, so a nullable column is enough.

import Fluent

struct AddClassCoverageRunGroup: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIClassCoverageRun.schema)
            .field("group_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIClassCoverageRun.schema)
            .deleteField("group_id")
            .update()
    }
}
