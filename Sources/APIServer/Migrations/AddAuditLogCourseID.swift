// APIServer/Migrations/AddAuditLogCourseID.swift
//
// First-class course scoping for audit events (#421).
//
// Course-scoped audit call sites have always stashed `course_id` inside the
// `metadata` JSON blob. That works for a human reading one row, but it cannot
// be indexed, cannot be filtered without a full scan, and is silently absent
// wherever a call site forgot the key. The per-course activity view needs to
// ask "every event for this course, newest first" on every page load, so the
// scope becomes a real column.
//
// Nullable by design: most audit events (logins, user deletion, runner secret
// rotation) belong to no course at all.
//
// The backfill reads the existing metadata so history predating the column
// still shows up in the view. It runs in Swift rather than SQL because the
// JSON accessor differs between Postgres (`metadata::json->>'course_id'`) and
// SQLite (`json_extract`), and this migration must produce the same result on
// both.

import Fluent
import Foundation
import SQLKit

struct AddAuditLogCourseID: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("audit_log")
            .field("course_id", .uuid)
            .update()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_log_course_created ON audit_log(course_id, created_at DESC)"
            ).run()
        }

        try await backfillFromMetadata(on: database)
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_course_created").run()
        }
        try await database.schema("audit_log")
            .deleteField("course_id")
            .update()
    }

    /// Copies `metadata.course_id` into the new column for existing rows.
    ///
    /// Best-effort: a row whose metadata is malformed or carries a non-UUID
    /// course id is left with a nil scope rather than failing the migration.
    /// An un-scoped historical row means one event missing from a course view;
    /// a failed migration means the server does not start.
    private func backfillFromMetadata(on database: Database) async throws {
        let candidates = try await APIAuditLogEntry.query(on: database)
            .filter(\.$metadata != nil)
            .all()

        for entry in candidates where entry.courseID == nil {
            guard let metadata = entry.metadata,
                metadata.contains("course_id"),
                let data = metadata.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String: String].self, from: data),
                let raw = decoded["course_id"],
                let courseID = UUID(uuidString: raw)
            else { continue }
            entry.courseID = courseID
            try await entry.save(on: database)
        }
    }
}
