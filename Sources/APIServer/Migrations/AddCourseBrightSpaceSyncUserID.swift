// APIServer/Migrations/AddCourseBrightSpaceSyncUserID.swift
//
// Adds `courses.brightspace_sync_user_id`: the instructor whose connected LEARN
// identity drives grade sync for that course (the "designated" identity).
// NULL = fall back to the deployment-wide (admin/env) identity.
//
// Like AddBrightSpaceOrgUnitName, this must be registered *before* any migration
// that queries the APICourse model (Fluent SELECTs every declared column, so the
// column has to exist on a fresh DB before e.g. AddCourseArchivedAt's backfill
// runs). Bare uuid (no FK), matching the existing brightspace_org_unit columns.

import Fluent

struct AddCourseBrightSpaceSyncUserID: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("brightspace_sync_user_id", .uuid)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("brightspace_sync_user_id")
            .update()
    }
}
