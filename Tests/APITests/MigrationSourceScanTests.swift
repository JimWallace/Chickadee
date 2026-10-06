// Tests/APITests/MigrationSourceScanTests.swift
//
// The helper the migration scans share reads all three ways a migration
// names its table (#2280).

import Foundation
import Testing

@Suite struct MigrationSourceScanTests {

    @Test func readsALiteralSchemaName() throws {
        #expect(try MigrationSourceScan.tables(in: #"database.schema("users").field("x", .string)"#) == ["users"])
    }

    @Test func resolvesAModelSchemaThroughTheModelFile() throws {
        let source = "database.schema(APIGitHubCourseRepository.schema).update()"
        #expect(try MigrationSourceScan.tables(in: source) == ["github_course_repositories"])
    }

    @Test func readsARawAlterTable() throws {
        let source = #"sql.raw("ALTER TABLE _fluent_sessions ADD COLUMN created_at TIMESTAMP")"#
        #expect(try MigrationSourceScan.tables(in: source) == ["_fluent_sessions"])
    }

    @Test func refusesAModelWhoseTableItCannotRead() {
        #expect(throws: MigrationSourceScan.ScanError.self) {
            try MigrationSourceScan.tables(in: "database.schema(NoSuchModel.schema).create()")
        }
    }

    /// The newest migration names its table through the model. The literal-only
    /// scan read no table in it at all.
    @Test func theNewestModelSchemaMigrationIsSeen() throws {
        let url = MigrationSourceScan.repoRoot
            .appendingPathComponent("Sources/APIServer/Migrations/AddGitHubCourseRepositoryInvitedUser.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(try MigrationSourceScan.tables(in: source).contains("github_course_repositories"))
    }
}
