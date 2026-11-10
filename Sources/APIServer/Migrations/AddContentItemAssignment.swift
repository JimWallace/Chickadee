// APIServer/Migrations/AddContentItemAssignment.swift
//
// The assignment a content item is attached to: an attached item renders as
// extra action buttons on that assignment's row (a lab's slides beside its
// notebook) instead of as a row of its own. Optional: nil is a standalone
// item, which is every item made before the column. No foreign key, as for
// every column added to an existing table; `AssignmentDeletion` detaches the
// items of a deleted assignment.

import Fluent

struct AddContentItemAssignment: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APICourseContentItem.schema)
            .field("assignment_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APICourseContentItem.schema)
            .deleteField("assignment_id")
            .update()
    }
}
