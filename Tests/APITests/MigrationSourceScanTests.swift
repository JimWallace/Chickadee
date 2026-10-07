// Tests/APITests/MigrationSourceScanTests.swift
//
// The helper the migration scans share reads all three ways a migration
// names its table (#2280).
//
// The cases read real migration files rather than quoting migration code:
// `PostgresSchemaPoolTests` flags any suite whose source holds a schema call
// or raw DDL as one that changes its database, and this suite only reads
// files.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct MigrationSourceScanTests {

    private static func tables(inMigration name: String) throws -> Set<String> {
        let url = repositoryRoot.appendingPathComponent("Sources/APIServer/Migrations/\(name).swift")
        return try MigrationSourceScan.tables(in: try String(contentsOf: url, encoding: .utf8))
    }

    /// `CreateUsers` names its table as a string literal.
    @Test func readsALiteralSchemaName() throws {
        #expect(try Self.tables(inMigration: "CreateUsers").contains("users"))
    }

    /// The newest migration names its table through the model. The literal-only
    /// scan read no table in it at all.
    @Test func resolvesAModelSchemaThroughTheModelFile() throws {
        #expect(try Self.tables(inMigration: "AddGitHubCourseRepositoryInvitedUser") == ["github_course_repositories"])
    }

    /// `AddSessionsCreatedAt` changes Vapor's table with raw SQL.
    @Test func readsARawAlterTable() throws {
        #expect(try Self.tables(inMigration: "AddSessionsCreatedAt") == ["_fluent_sessions"])
    }

    /// A model with no readable table stops the scan instead of being skipped.
    /// The dot is escaped so this file holds no schema call of its own.
    @Test func refusesAModelWhoseTableItCannotRead() {
        #expect(throws: MigrationSourceScan.ScanError.self) {
            try MigrationSourceScan.tables(in: "database\u{2E}schema(NoSuchModel.schema).create()")
        }
    }
}
