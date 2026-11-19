// Tests/APITests/Guards/SchemaDesignTests.swift
//
// Design rules for the migrated schema, checked against the catalog. Each
// rule names a defect class that a load test or an audit found after it
// shipped (docs/database-design.md). The allowlist holds what was already
// there when the rule arrived. It may only shrink: an entry that no longer
// applies fails the test too. The foreign-key index rule is
// `ForeignKeyIndexCoverageTests` (docs/database-performance.md).

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct SchemaDesignTests {

    // MARK: - Allowlists

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

    /// An index whose columns lead another index on the same table serves no
    /// query the wider one does not, and every write maintains it (the
    /// 2026-11 audit found four; `DropCoveredIndexes` removed them).
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
