// Tests/APITests/MigrationIndexCoverageTests.swift
//
// Every `idx_*` index the migrations declare exists after migration, and no
// other does (#1809). A raw `CREATE INDEX IF NOT EXISTS` runs behind a
// `guard let sql = database as? SQLDatabase` and cannot fail loudly, so an
// index that silently did nothing on one dialect left a scan nobody noticed.
//
// The expected set is derived from the migration sources: every index a
// `prepare` creates, minus every index a later `prepare` drops. The
// derivation asserts its own size, so a parse that goes quietly partial
// cannot pass as a correct one.

import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class MigrationIndexCoverageTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-idx-cover")
    }

    /// The `idx_*` names the migrations leave in place after every `prepare`
    /// has run: created in some `prepare`, not dropped in another.
    static func declaredIndexNames() throws -> Set<String> {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let migrations = root.appendingPathComponent("Sources/APIServer/Migrations")
        let files = try FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // An index is created either as raw SQL or through the SQLKit builder;
        // both shapes are read, so a migration written either way is covered.
        let create = [
            try Regex(#"CREATE (?:UNIQUE )?INDEX (?:IF NOT EXISTS )?(idx_[a-z0-9_]+)"#),
            try Regex(#"create\(index: "(idx_[a-z0-9_]+)""#),
        ]
        let drop = [
            try Regex(#"DROP INDEX (?:IF EXISTS )?(idx_[a-z0-9_]+)"#),
            try Regex(#"drop\(index: "(idx_[a-z0-9_]+)""#),
        ]

        var created: Set<String> = []
        var dropped: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Only `prepare` shapes the schema; `revert` is the mirror image.
            let prepare = source.components(separatedBy: "func revert(").first ?? source
            let createdHere = Self.names(in: prepare, matching: create)
            let droppedHere = Self.names(in: prepare, matching: drop)
            created.formUnion(createdHere)
            // A drop followed by a create of the same name in one `prepare` is
            // a redefinition, not a removal.
            dropped.formUnion(droppedHere.subtracting(createdHere))
        }
        // The one migration that builds its statements from a list.
        created.formUnion(CreateSweepAndPollIndexes.indexes.map(\.name))
        return created.subtracting(dropped)
    }

    /// The first capture of every match of any of `patterns` in `source`.
    private static func names(in source: String, matching patterns: [Regex<AnyRegexOutput>]) -> Set<String> {
        Set(
            patterns.flatMap { pattern in
                source.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) }
            })
    }

    @Test func everyDeclaredIndexExistsAndNoOther() async throws {
        try await withApp(app) { app in
            let declared = try Self.declaredIndexNames()
            // The derivation must be complete, not merely non-empty: a parse
            // that found a handful would otherwise pass against a handful.
            #expect(declared.count >= 40, "parsed only \(declared.count) index names")

            let sql = try #require(app.db as? SQLDatabase)
            // On Postgres, only this app's schema: the lane runs suites in
            // parallel, each in its own schema, and a schema another suite is
            // still migrating holds indexes a later migration drops.
            let query: SQLQueryString =
                sql.dialect.name == "postgresql"
                ? "SELECT indexname AS name FROM pg_indexes WHERE schemaname = current_schema()"
                : "SELECT name FROM sqlite_master WHERE type = 'index'"
            let rows = try await sql.raw(query).all()
            let present = Set(try rows.map { try $0.decode(column: "name", as: String.self) })
                .filter { $0.hasPrefix("idx_") }
            #expect(
                present == declared,
                "missing: \(declared.subtracting(present).sorted()); undeclared: \(present.subtracting(declared).sorted())"
            )
        }
    }
}
