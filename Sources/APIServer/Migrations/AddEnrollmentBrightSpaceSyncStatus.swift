// APIServer/Migrations/AddEnrollmentBrightSpaceSyncStatus.swift
//
// Per-(student, course) LEARN grade-sync readiness on `course_enrollments`.
// A student starts `unconfirmed` (we have not yet verified we can deliver
// their grade to LEARN); the periodic roster-readiness sweep resolves them
// against the course's LEARN classlist and flips them to `confirmed` (matched
// — we can push) or `unreachable` (not on the classlist / no key to match on,
// with a reason in `detail`).
//
// Three nullable columns added one at a time — SQLite can't add multiple
// columns (or a NOT NULL column) to an existing table in one ALTER, the same
// constraint that keeps `role` / `url_token` nullable. The model reads the
// status through a typed accessor that treats a NULL (pre-existing row, never
// swept) as `.unconfirmed`.

import Fluent
import SQLKit

struct AddEnrollmentBrightSpaceSyncStatus: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .field("brightspace_sync_status", .string)
            .update()
        try await database.schema("course_enrollments")
            .field("brightspace_checked_at", .datetime)
            .update()
        try await database.schema("course_enrollments")
            .field("brightspace_sync_detail", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        // One DROP COLUMN per ALTER — SQLite rejects multi-column ALTERs, the
        // same constraint that splits the adds above.
        try await database.schema("course_enrollments")
            .deleteField("brightspace_sync_status")
            .update()
        try await database.schema("course_enrollments")
            .deleteField("brightspace_checked_at")
            .update()
        try await database.schema("course_enrollments")
            .deleteField("brightspace_sync_detail")
            .update()
    }
}
