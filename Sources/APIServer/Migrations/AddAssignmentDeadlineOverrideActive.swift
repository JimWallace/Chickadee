// APIServer/Migrations/AddAssignmentDeadlineOverrideActive.swift
//
// CONSOLIDATED.  `deadline_override_active` is folded into
// CreateAssignments as of v0.4.171.  Struct name preserved so existing
// prod's `_fluent_migrations` tracking is undisturbed; no-op on fresh
// deploys.

import Fluent

struct AddAssignmentDeadlineOverrideActive: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateAssignments.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
