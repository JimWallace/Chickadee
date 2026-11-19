// Tests/APITests/Guards/ForeignKeyIndexCoverageTests.swift
//
// Every foreign key has an index that leads with its column, unless its table
// stays small. Postgres does not index the referencing side of a foreign key,
// so a delete of a referenced row scans the whole referencing table. At one
// course's scale an unindexed `request_metrics.submission_id` made each
// deleted submission a 34 ms scan (docs/database-performance.md).
//
// A new foreign key fails this test until it gets an index or a reason on the
// list below.

import ChickadeeTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ForeignKeyIndexCoverageTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-fk-index")
    }

    /// "table.column" foreign keys that have no index on purpose. Each table
    /// holds a row per course, per assignment, per student and assignment, or
    /// per rare event, so the scan a delete causes stays small.
    static let unindexedOnPurpose: Set<String> = [
        // A user or a course is deleted one at a time: one scan per delete
        // costs less than an index entry on each insert, and these tables
        // take a row per request or per job (CreateForeignKeyIndexes).
        "user_activity_events.user_id",
        "client_diagnostics.user_id",
        "job_execution_metrics.user_id",
        "job_execution_metrics.course_id",
        "submission_diagnostics.course_id",
        // Small tables.
        "assignment_participations.assignment_id",
        "assignment_personalization_seeds.assignment_id",
        "assignments.section_id",
        "leaderboard_entries.user_id",
        "activity_champions.user_id",
        "activity_standings.user_id",
        "activity_sessions.opened_by",
        "activity_sessions.group_id",
        "lti_login_states.platform_id",
        "lti_identities.user_id",
        "lti_deep_link_requests.user_id",
        "lti_deep_link_requests.course_id",
        "lti_deep_link_requests.platform_id",
        "reflection_feedback.user_id",
        "reflection_feedback.reviewed_by_user_id",
        "composite_slots.user_id",
        "composite_contributions.user_id",
        "composite_contributions.submission_id",
        "composite_references.submission_id",
        "composite_spares.user_id",
        "composite_spares.submission_id",
        "course_personalization_seeds.course_id",
        "dataset_deals.user_id",
        "course_group_sets.course_id",
        "course_group_memberships.user_id",
        "course_group_memberships.group_id",
        "activity_session_attendance.user_id",
        "group_activity_champions.user_id",
        "group_leaderboard_entries.user_id",
        "group_composite_slots.user_id",
        "group_composite_spares.user_id",
        "group_composite_spares.submission_id",
        "class_achievements.user_id",
        "secret_reveal_unlocks.assignment_id",
        "course_content_items.section_id",
        // Staff actions: one row per grant, override, refund or edit.
        "assignment_extensions.granted_by_user_id",
        "grade_overrides.granted_by_user_id",
        "slip_day_spends.refunded_by_user_id",
        "slip_day_spends.assignment_id",
        "assignment_versions.actor_user_id",
        "brightspace_grade_clears.user_id",
        // OAuth: a row per connected client, consent or short-lived code.
        "oauth_authorization_codes.user_id",
        "oauth_grants.user_id",
        "oauth_consent_requests.user_id",
        "oauth_clients.created_by",
    ]

    private struct UnindexedForeignKey: Decodable {
        let tableName: String
        let columns: String

        enum CodingKeys: String, CodingKey {
            case tableName = "table_name"
            case columns
        }
    }

    @Test func everyForeignKeyHasALeadingIndexOrAReason() async throws {
        try await withApp(app) { app in
            let sql = try #require(app.db as? any SQLDatabase)
            // Only this app's schema: the suite runs in parallel, each test in
            // its own schema.
            let rows = try await sql.raw(
                """
                SELECT c.conrelid::regclass::text AS table_name,
                       string_agg(a.attname, ',' ORDER BY x.n) AS columns
                FROM pg_constraint c
                JOIN pg_namespace ns ON ns.oid = c.connamespace
                CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
                WHERE c.contype = 'f'
                  AND ns.nspname = current_schema()
                  AND NOT EXISTS (
                    SELECT 1 FROM pg_index i
                    WHERE i.indrelid = c.conrelid AND (i.indkey::int2[])[0] = c.conkey[1])
                GROUP BY c.conrelid, c.conname
                """
            ).all(decoding: UnindexedForeignKey.self)
            // `regclass::text` may carry the schema prefix; keep the table.
            let found = Set(
                rows.map { row in
                    "\(row.tableName.split(separator: ".").last.map(String.init) ?? row.tableName).\(row.columns)"
                })

            // The query must see foreign keys at all, or an empty result
            // would pass for the wrong reason.
            #expect(!found.isEmpty, "found no unindexed foreign keys, not even the listed ones")
            let missing = found.subtracting(Self.unindexedOnPurpose)
            #expect(
                missing.isEmpty,
                """
                Foreign keys with no index that leads with their column: \(missing.sorted()). \
                A delete of the referenced row scans the whole table. Add an index in a migration, \
                or add the key to `unindexedOnPurpose` under the group that gives its reason.
                """)
            let stale = Self.unindexedOnPurpose.subtracting(found)
            #expect(stale.isEmpty, "listed but now indexed or gone; remove them: \(stale.sorted())")
        }
    }
}
