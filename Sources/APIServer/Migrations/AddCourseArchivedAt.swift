// APIServer/Migrations/AddCourseArchivedAt.swift
//
// Adds the `archived_at` column to `courses`.  This stamps *when* a course
// was archived, which is the signal Chickadee uses for "end of term": the
// submission-retention policy purges student submissions one year (the
// SUBMISSION_RETENTION_DAYS window) after a course is archived.
//
// Chickadee has no first-class term/semester concept, so archiving a course
// is the operator action that marks the term over.  `is_archived` alone only
// records *that* a course is archived, not *when* — without a timestamp the
// retention clock has nothing to count from.
//
// Migration shape mirrors AddUrlTokenToUsers:
//   1. Add `archived_at` as a nullable datetime column.
//   2. Backfill: every currently-archived course gets `archived_at` set to
//      its `created_at`.  We don't know the real archival date for courses
//      archived before this column existed, so we use the earliest defensible
//      timestamp (creation).  Because the retention feature is report-first —
//      an admin reviews and clicks Purge, nothing auto-deletes — surfacing
//      these older courses as already-eligible is the desired behaviour, not
//      a hazard.  Going forward `toggleCourseArchive` stamps the real time.

import Fluent
import Foundation

struct AddCourseArchivedAt: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("archived_at", .datetime)
            .update()

        // Backfill existing archived courses with their creation timestamp.
        let archived = try await APICourse.query(on: database)
            .filter(\.$isArchived == true)
            .all()
        for course in archived where course.archivedAt == nil {
            course.archivedAt = course.createdAt
            try await course.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("archived_at")
            .update()
    }
}
