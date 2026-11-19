// Tests/APITests/Guards/StudentWorkDeletionCoverageTests.swift
//
// Deleting an assignment or a course leaves no row that points at what it
// deleted. Many tables key a row by `test_setup_id`, `submission_id` or
// `assignment_id` with no foreign key, so only `SetupRowDeletion` removes them,
// and before this guard nine such tables were missed: their rows kept a
// student's ID and submission after the admin was told "Deleted ... and all
// its data".
//
// The tables come from the catalog, not from a list here. The test puts one
// row keyed to the doomed assignment into every table that has a key column,
// runs the real delete, and counts what is left. A new table is covered the
// day it is migrated: it fails here until the delete removes its rows, or it
// is named in `keptOnPurpose` with the reason.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct StudentWorkDeletionCoverageTests {

    /// Which delete runs, and which key columns must then match no row.
    enum Path: String, CaseIterable, Sendable, CustomStringConvertible {
        case assignment
        case course

        var description: String { rawValue }

        /// The columns that name what this delete removes. The course delete
        /// also removes everything keyed to the course.
        var keyColumns: [String] {
            switch self {
            case .assignment: return ["test_setup_id", "submission_id", "assignment_id"]
            case .course: return ["test_setup_id", "submission_id", "assignment_id", "course_id"]
            }
        }

        /// Tables whose rows outlive this delete by design, with the reason.
        /// An entry for a table that no longer exists, or no longer has a
        /// key column, fails the test.
        var keptOnPurpose: [String: String] {
            switch self {
            case .assignment:
                return [
                    // Content history outlives the assignment delete
                    // (CreateAssignmentVersions); the course delete removes it.
                    "assignment_versions": "content history, removed with the course",
                    // A grade push log is history (CreateBrightSpaceSyncLog).
                    "brightspace_sync_log": "grade push history",
                ]
            case .course:
                return [
                    // Kept even after a course purge
                    // (docs/operational-diagnostics.md, BrightSpace sync log).
                    "brightspace_sync_log": "grade push history",
                    // The admin audit trail records the delete itself.
                    "audit_log": "audit trail",
                ]
            }
        }
    }

    /// The rows that every seeded row may point at.
    struct Fixture {
        let course: APICourse
        let assignment: APIAssignment
        let setupID: String
        let submissionID: String

        /// The value each key column takes in a seeded row, as a SQL literal.
        /// Every value is a test-owned UUID or ID, so it needs no escaping.
        func keyLiteral(for column: String) throws -> String? {
            switch column {
            case "test_setup_id": return "'\(setupID)'"
            case "submission_id": return "'\(submissionID)'"
            case "assignment_id": return "'\(try assignment.requireID().uuidString)'"
            case "course_id": return "'\(try course.requireID().uuidString)'"
            default: return nil
            }
        }

        /// Tables keyed by something other than a key column, and the values
        /// that key a seeded row the way the server keys a real one. The award
        /// ledger names its owner by level: an assignment-level award's
        /// owner is the setup (`AchievementAwardStore`).
        func ownerLiterals(for table: String) -> [String: String] {
            switch table {
            case "achievement_awards":
                return ["level": "'\(AchievementLevel.assignment.rawValue)'", "owner_id": "'\(setupID)'"]
            default:
                return [:]
            }
        }
    }

    /// The tables the fixture writes through the models, which the seeding
    /// leaves alone.
    static let fixtureTables: Set<String> = ["courses", "users", "test_setups", "assignments", "submissions"]

    @Test(arguments: Path.allCases)
    func theDeleteLeavesNoRowKeyedToWhatItDeleted(path: Path) async throws {
        try await withTestApp(prefix: "chickadee-deletion-coverage") { app in
            let fixture = try await makeFixture(on: app)
            let catalog = try await SchemaCatalog.load(on: app.db)
            let keyed = keyedTables(in: catalog, path: path)
            #expect(keyed.count > 20, "sanity: the catalog names the setup-keyed tables")

            let stale = Set(path.keptOnPurpose.keys).subtracting(keyed)
            #expect(stale.isEmpty, "keptOnPurpose names tables with no key column: \(stale.sorted())")

            try await seedOneRowPerTable(catalog: catalog, fixture: fixture, on: app.db)

            switch path {
            case .assignment:
                _ = try await app.db.transaction { db in
                    try await AssignmentDeletion.deleteRows(of: fixture.assignment, on: db)
                }
            case .course:
                _ = try await app.db.transaction { db in
                    try await CoursePurge.deleteRows(
                        of: fixture.course, setupsDirectory: app.testSetupsDirectory, on: db)
                }
            }

            var leftBehind: [String] = []
            for table in keyed.sorted() where path.keptOnPurpose[table] == nil {
                let count = try await countRows(
                    in: table, keyedBy: path, catalog: catalog, fixture: fixture, on: app.db)
                if count > 0 { leftBehind.append("\(table) (\(count))") }
            }
            #expect(
                leftBehind.isEmpty,
                """
                the \(path) delete left rows that name what it deleted: \(leftBehind). \
                Delete them in SetupRowDeletion, or add the table to keptOnPurpose with the reason.
                """)
        }
    }

    // MARK: - Helpers

    private func makeFixture(on app: Application) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "DEL101", archived: true)
        let courseID = try course.requireID()
        let setupID = "setup_deletion_coverage"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        let student = try await makeTestStudent(on: app, username: "deletion_coverage_student")
        let submission = try await makeTestSubmission(
            on: app, id: "sub_deletion_coverage", setupID: setupID, userID: try student.requireID())
        return Fixture(
            course: course, assignment: assignment, setupID: setupID, submissionID: try submission.requireID())
    }

    /// Every table with a column that this delete's keys name.
    private func keyedTables(in catalog: SchemaCatalog, path: Path) -> Set<String> {
        Set(catalog.columns.filter { path.keyColumns.contains($0.name) }.map(\.table))
    }

    /// Inserts one row into every table with any key column, outside the
    /// fixture's own tables. Each key column gets the fixture's value; each
    /// other required column a foreign-key target from the fixture or a
    /// filler of its type. A table whose target table is still empty waits
    /// for a later pass.
    private func seedOneRowPerTable(catalog: SchemaCatalog, fixture: Fixture, on db: any Database) async throws {
        let sql = try #require(db as? any SQLDatabase)
        let allKeys = Path.course.keyColumns
        var pending = Set(catalog.columns.filter { allKeys.contains($0.name) }.map(\.table))
            .subtracting(Self.fixtureTables)
        // A required foreign key whose table holds no key column (an LTI
        // platform, a group set) needs a row of its own to point at.
        var frontier = pending
        while let table = frontier.popFirst() {
            for target in requiredTargets(of: table, in: catalog)
            where !pending.contains(target) && !Self.fixtureTables.contains(target) {
                pending.insert(target)
                frontier.insert(target)
            }
        }
        var seeded: Set<String> = Self.fixtureTables
        for _ in 0..<8 where !pending.isEmpty {
            for table in pending.sorted() {
                let targets = requiredTargets(of: table, in: catalog)
                guard targets.allSatisfy({ seeded.contains($0) || $0 == table }) else { continue }
                try await insertRow(into: table, catalog: catalog, fixture: fixture, on: sql)
                seeded.insert(table)
                pending.remove(table)
            }
        }
        if !pending.isEmpty {
            throw IssueRecorded("could not seed (their foreign-key targets stay empty): \(pending.sorted())")
        }
    }

    /// The tables that a row of `table` must point at.
    private func requiredTargets(of table: String, in catalog: SchemaCatalog) -> [String] {
        catalog.columns(of: table)
            .filter { !$0.isNullable && !$0.hasDefault }
            .compactMap { catalog.foreignKey(on: table, column: $0.name)?.referencedTable }
    }

    private func insertRow(
        into table: String, catalog: SchemaCatalog, fixture: Fixture, on sql: any SQLDatabase
    ) async throws {
        var names: [String] = []
        var values: [String] = []
        for column in catalog.columns(of: table) {
            let value: String
            if let key = try fixture.keyLiteral(for: column.name) {
                value = key
            } else if let owner = fixture.ownerLiterals(for: table)[column.name] {
                value = owner
            } else if column.isNullable || column.hasDefault {
                continue
            } else if let target = catalog.foreignKey(on: table, column: column.name)?.referencedTable {
                value = "(SELECT id FROM \"\(target)\" LIMIT 1)"
            } else {
                value = try filler(for: column)
            }
            names.append("\"\(column.name)\"")
            values.append(value)
        }
        let statement =
            "INSERT INTO \"\(table)\" (\(names.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
        do {
            try await sql.raw("\(unsafeRaw: statement)").run()
        } catch {
            throw IssueRecorded("seeding \(table) failed: \(String(reflecting: error))\n\(statement)")
        }
    }

    /// A value of the column's type, unique enough not to meet a unique
    /// constraint.
    private func filler(for column: CatalogColumn) throws -> String {
        switch column.type {
        case "text", "character varying":
            return "'seed_\(UUID().uuidString.prefix(8).lowercased())'"
        case "uuid": return "gen_random_uuid()"
        case "bigint", "integer", "smallint", "double precision", "numeric", "real": return "0"
        case "boolean": return "false"
        case "timestamp with time zone", "timestamp without time zone", "date": return "now()"
        case "jsonb", "json": return "'{}'"
        default:
            throw IssueRecorded("no filler for \(column.qualified) of type \(column.type); add one here")
        }
    }

    private func countRows(
        in table: String, keyedBy path: Path, catalog: SchemaCatalog, fixture: Fixture, on db: any Database
    ) async throws -> Int {
        let sql = try #require(db as? any SQLDatabase)
        let present = Set(catalog.columns(of: table).map(\.name))
        let conditions = try path.keyColumns.filter(present.contains).compactMap { column in
            try fixture.keyLiteral(for: column).map { "\"\(column)\" = \($0)" }
        }
        let statement =
            "SELECT count(*) AS n FROM \"\(table)\" WHERE \(conditions.joined(separator: " OR "))"
        let row = try #require(try await sql.raw("\(unsafeRaw: statement)").first())
        return try row.decode(column: "n", as: Int.self)
    }
}
