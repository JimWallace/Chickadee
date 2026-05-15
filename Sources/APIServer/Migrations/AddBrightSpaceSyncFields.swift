// APIServer/Migrations/AddBrightSpaceSyncFields.swift
//
// CONSOLIDATED.  The BrightSpace fields are folded into the appropriate
// Create* files as of v0.4.171:
//
//   - courses.brightspace_org_unit_id           → CreateCourses
//   - assignments.brightspace_grade_object_id   → CreateAssignments
//   - users.brightspace_user_id                 → CreateUsers
//   - results.brightspace_sync_pending          → CreateResults
//   - results.brightspace_pending_since         → CreateResults
//   - results.brightspace_synced_at             → CreateResults
//   - results.brightspace_sync_error            → CreateResults
//
// Struct name preserved so existing prod's `_fluent_migrations` tracking
// is undisturbed; no-op on fresh deploys.

import Fluent

struct AddBrightSpaceSyncFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see the Create* files listed above.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
