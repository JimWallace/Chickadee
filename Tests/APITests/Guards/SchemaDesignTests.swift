// Tests/APITests/Guards/SchemaDesignTests.swift
//
// Design rules for the migrated schema, checked against the catalog. Each
// rule names a defect class that a load test or an audit found after it
// shipped (docs/database-design.md). The allowlists hold what was already
// there when the rule arrived, each with its reason. They may only shrink:
// an entry that no longer applies fails the test too.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct SchemaDesignTests {

    // MARK: - Allowlists

    /// Foreign keys to `users` with no index. Only the admin user delete
    /// removes a user, and it then scans each of these tables once. Index one
    /// when a read path filters on it.
    static let unindexedUserForeignKeys: Set<String> = [
        "activity_champions.user_id", "activity_session_attendance.user_id",
        "activity_sessions.opened_by", "activity_standings.user_id",
        "assignment_extensions.granted_by_user_id", "assignment_versions.actor_user_id",
        "brightspace_grade_clears.user_id", "class_achievements.user_id", "client_diagnostics.user_id",
        "composite_contributions.user_id", "composite_slots.user_id", "composite_spares.user_id",
        "course_group_memberships.user_id", "dataset_deals.user_id", "grade_overrides.granted_by_user_id",
        "group_activity_champions.user_id", "group_composite_slots.user_id",
        "group_composite_spares.user_id", "group_leaderboard_entries.user_id",
        "job_execution_metrics.user_id", "leaderboard_entries.user_id", "lti_deep_link_requests.user_id",
        "lti_identities.user_id", "oauth_authorization_codes.user_id", "oauth_clients.created_by",
        "oauth_consent_requests.user_id", "oauth_grants.user_id", "reflection_feedback.reviewed_by_user_id",
        "reflection_feedback.user_id", "slip_day_spends.refunded_by_user_id",
        "submissions.retested_by_user_id", "user_activity_events.user_id",
    ]

    /// Other foreign keys with no index, and why.
    static let unindexedForeignKeys: [String: String] = [
        // SET NULL on a course or assignment delete: one scan per deleted
        // parent row, on an admin path. The setup key is indexed.
        "submission_diagnostics.assignment_id": "one scan per course or assignment delete",
        "submission_diagnostics.course_id": "one scan per course delete",
        "job_execution_metrics.assignment_id": "one scan per course or assignment delete",
        "job_execution_metrics.course_id": "one scan per course delete",
        // Single-use deep-link tickets, reaped within minutes.
        "lti_deep_link_requests.course_id": "short-lived rows",
        "lti_deep_link_requests.platform_id": "short-lived rows",
    ]

    /// Text columns that hold JSON. A new JSON column is `jsonb`, which
    /// Postgres validates and can index; these predate the rule.
    static let textJSONColumns: Set<String> = [
        "assignment_requirements.required_capabilities_json",
        "assignment_requirements.required_languages_json",
        "course_content_items.attachments_json",
        "course_content_items.links_json",
        "course_dataset_versions.columns_json",
        "result_collections.collection_json",
        "runner_profiles.capabilities_json",
        "runner_profiles.language_versions_json",
        "submissions.materialization_json",
    ]

    // MARK: - Rules

    /// Postgres does not index the referencing side of a foreign key. Without
    /// one, each deleted parent row scans the child table, and a lookup by
    /// parent scans it too (#2913, and `request_metrics.submission_id`, which
    /// a course purge scanned once per submission).
    @Test func everyForeignKeyHasAnIndex() async throws {
        try await withTestApp(prefix: "chickadee-schema-fk") { app in
            let catalog = try await SchemaCatalog.load(on: app.db)
            let unindexed = Set(
                catalog.foreignKeys.filter { key in
                    !catalog.indexes.contains { $0.table == key.table && $0.columns.first == key.column }
                }.map(\.qualified))
            let allowed = Self.unindexedUserForeignKeys.union(Self.unindexedForeignKeys.keys)
            #expect(catalog.foreignKeys.count > 80, "sanity: the catalog lists the foreign keys")
            #expect(
                unindexed.subtracting(allowed).isEmpty,
                "foreign keys with no index; add one in the table's migration: \(unindexed.subtracting(allowed).sorted())"
            )
            #expect(
                allowed.subtracting(unindexed).isEmpty,
                "allowlisted foreign keys that now have an index; remove them: \(allowed.subtracting(unindexed).sorted())"
            )
        }
    }

    /// An index whose columns lead another index on the same table serves no
    /// query the wider one does not, and every write maintains it (#2913
    /// audit: four of them).
    @Test func noIndexIsCoveredByAnother() async throws {
        try await withTestApp(prefix: "chickadee-schema-idx") { app in
            let catalog = try await SchemaCatalog.load(on: app.db)
            let full = catalog.indexes.filter { !$0.isPartial && !$0.columns.contains("") }
            var covered: [String] = []
            for index in full where !index.isPrimary {
                for other in full where other.table == index.table && other.name != index.name {
                    let isPrefix = other.columns.starts(with: index.columns)
                    let isDuplicate = other.columns == index.columns
                    // A unique index is not redundant beside a wider one: it
                    // enforces uniqueness on fewer columns.
                    guard isPrefix, !index.isUnique || isDuplicate else { continue }
                    // Of two identical indexes, report the non-unique one, or
                    // the later name.
                    if isDuplicate, index.isUnique && !other.isUnique { continue }
                    if isDuplicate, index.isUnique == other.isUnique, index.name < other.name { continue }
                    covered.append("\(index.name) (covered by \(other.name))")
                }
            }
            #expect(covered.isEmpty, "redundant indexes: \(covered.sorted())")
        }
    }

    /// Timestamps carry their time zone, and JSON is `jsonb`.
    @Test func columnTypesFollowTheConventions() async throws {
        try await withTestApp(prefix: "chickadee-schema-types") { app in
            let catalog = try await SchemaCatalog.load(on: app.db)
            let naive = catalog.columns.filter { $0.type == "timestamp without time zone" }.map(\.qualified)
            #expect(naive.isEmpty, "use .datetime (timestamptz): \(naive.sorted())")

            let plainJSON = catalog.columns.filter { $0.type == "json" }.map(\.qualified)
            #expect(plainJSON.isEmpty, "use jsonb, not json: \(plainJSON.sorted())")

            let textJSON = Set(
                catalog.columns.filter { $0.name.hasSuffix("_json") && $0.type != "jsonb" }.map(\.qualified))
            #expect(
                textJSON.subtracting(Self.textJSONColumns).isEmpty,
                "new JSON columns stored as text; use jsonb: \(textJSON.subtracting(Self.textJSONColumns).sorted())"
            )
            #expect(
                Self.textJSONColumns.subtracting(textJSON).isEmpty,
                "textJSONColumns entries that are gone; remove them: \(Self.textJSONColumns.subtracting(textJSON).sorted())"
            )
        }
    }
}
