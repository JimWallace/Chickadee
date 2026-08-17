// Keeps deploy/sql/mcp-least-privilege-role.sql in sync with the tables the
// MCP read path actually touches.
//
// The least-privilege `chickadee_mcp` Postgres role is deny-by-omission: any
// table the MCP tools read must carry an explicit GRANT in that file, or every
// affected tool call fails in production with "permission denied" — invisible
// to the SQLite/owner-role test runs. That is exactly how #1176's
// `result_collections` side table broke `get_validation_result` (the grants
// file predated the table). This suite fails the build when a table read
// through `MCPStudentDataBoundary` (or its blob side table) is missing a
// SELECT grant or its row-level-security policy.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPLeastPrivilegeGrantSyncTests {
    /// `deploy/sql/mcp-least-privilege-role.sql`, resolved from this test
    /// file's location (same technique as MCPStudentDataWallTests).
    private static var grantsFile: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("deploy/sql/mcp-least-privilege-role.sql")
    }

    /// Student-data tables the MCP read path queries: the two the boundary
    /// accessors filter to validation rows, the collection-blob side table
    /// `loadCollectionJSON` joins in, and the multi-variant validation batch
    /// `get_validation_result` reports. Grown deliberately by hand — a new
    /// table here must come with a grant AND an RLS policy in the SQL file.
    private static let readTables: [String] = [
        APISubmission.schema,
        APIResult.schema,
        APIResultCollection.schema,
        ValidationVariant.schema,
    ]

    @Test func everyMCPReadTableHasSelectGrant() throws {
        let sql = try String(contentsOf: Self.grantsFile, encoding: .utf8)
        // Collapse whitespace so multi-line GRANT statements parse the same.
        let flat = sql.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)

        let grantedTables =
            flat
            .components(separatedBy: "GRANT SELECT ON ")
            .dropFirst()
            .compactMap { $0.components(separatedBy: " TO chickadee_mcp").first }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for table in Self.readTables {
            #expect(
                grantedTables.contains(table),
                "\(table) is read by the MCP tool surface but has no SELECT grant in deploy/sql/mcp-least-privilege-role.sql — every call reading it will fail in production with a permission-denied the tests cannot see"
            )
        }
    }

    @Test func everyMCPReadTableHasRowLevelSecurityPolicy() throws {
        let sql = try String(contentsOf: Self.grantsFile, encoding: .utf8)
        for table in Self.readTables {
            #expect(
                sql.contains("ALTER TABLE \(table) ENABLE ROW LEVEL SECURITY"),
                "\(table) is granted to chickadee_mcp but has no RLS enablement — the role would see student rows, defeating the student-data wall"
            )
            #expect(
                sql.contains("ON \(table)\n    FOR SELECT TO chickadee_mcp"),
                "\(table) has no SELECT policy for chickadee_mcp in the grants file")
        }
    }
}
