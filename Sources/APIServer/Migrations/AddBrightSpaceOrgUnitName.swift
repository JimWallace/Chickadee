// APIServer/Migrations/AddBrightSpaceOrgUnitName.swift
//
// Adds the optional `brightspace_org_unit_name` column to `courses`: the
// human-readable D2L org-unit name, cached when an admin binds a course to
// its org unit (we look the ID up in D2L and store the name so the binding
// is verifiable at a glance).  nil = not bound, or bound but not yet verified.
//
// Standalone Add* migration (not folded into CreateCourses) because
// production databases have already applied CreateCourses without this
// column and would never pick it up from a body change.  Fresh deploys run
// CreateCourses then this migration; existing prod runs only this one.

import Fluent

struct AddBrightSpaceOrgUnitName: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("brightspace_org_unit_name", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("brightspace_org_unit_name")
            .update()
    }
}
