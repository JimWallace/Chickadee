// APIServer/Migrations/AddGradeOverrideBrightSpaceSync.swift
//
// Adds BrightSpace grade-sync bookkeeping columns to `grade_overrides`,
// mirroring the four columns already on `results`
// (brightspace_sync_pending / _pending_since / _synced_at / _sync_error).
//
// Why the override row needs its own sync flags: the grade-sync sweep is
// driven by pending flags, but a student with NO submissions has no `results`
// row to flag.  An instructor override on such a student (e.g. a pre-enrolled
// student manually registered for grade-sync testing) is the only thing to
// push, so the override row itself carries the pending flag the sweep scans.
//
// Standalone Add* migration (not folded into CreateGradeOverrides) because
// production databases have already applied CreateGradeOverrides without these
// columns and would never pick them up from a body change.  Fresh deploys run
// CreateGradeOverrides then this migration; existing prod runs only this one.

import Fluent

struct AddGradeOverrideBrightSpaceSync: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One ADD COLUMN per statement — SQLite rejects a multi-column ALTER.
        try await database.schema("grade_overrides")
            .field("brightspace_sync_pending", .bool).update()
        try await database.schema("grade_overrides")
            .field("brightspace_pending_since", .datetime).update()
        try await database.schema("grade_overrides")
            .field("brightspace_synced_at", .datetime).update()
        try await database.schema("grade_overrides")
            .field("brightspace_sync_error", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("grade_overrides")
            .deleteField("brightspace_sync_error").update()
        try await database.schema("grade_overrides")
            .deleteField("brightspace_synced_at").update()
        try await database.schema("grade_overrides")
            .deleteField("brightspace_pending_since").update()
        try await database.schema("grade_overrides")
            .deleteField("brightspace_sync_pending").update()
    }
}
