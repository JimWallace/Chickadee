// APIServer/Migrations/AddAssignmentBrightSpaceSyncExcluded.swift
//
// Adds the optional `brightspace_sync_excluded` column to the assignments
// table: an explicit "do not sync this assignment's grades to LEARN" flag,
// distinct from an unmapped grade item (which only means "not wired up yet").
//
// Shipped as a standalone Add* migration (not folded into CreateAssignments)
// for the same reason as AddAssignmentStartsAt: production databases have
// already applied CreateAssignments without this column and would never pick
// it up from a body change. Fresh deploys run CreateAssignments then this
// migration; existing prod runs only this one.

import Fluent

struct AddAssignmentBrightSpaceSyncExcluded: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("brightspace_sync_excluded", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("brightspace_sync_excluded")
            .update()
    }
}
