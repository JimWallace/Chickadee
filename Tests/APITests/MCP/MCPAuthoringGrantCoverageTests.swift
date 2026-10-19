// Keeps deploy/sql/mcp-least-privilege-role.sql in step with the tables the
// MCP tool code names.
//
// The `chickadee_mcp` role is deny-by-omission. A table that an MCP tool
// queries on `ToolContext.db` with no GRANT fails in production with
// "permission denied", and the SQLite and owner-role test runs cannot see it.
// `course_content_items` broke every content-item tool this way.
//
// `MCPLeastPrivilegeGrantSyncTests` covers the student-data tables behind
// `MCPStudentDataBoundary` and their RLS policies. This suite covers the rest:
// it finds each Fluent model that the scanned files name in code, maps it to
// its `schema`, and requires a GRANT for that table. A file that names a table
// it reaches only on the owner pool (`ToolContext.mainDB`) goes in
// `ownerPoolOnly`, with the reason.
//
// What it does not see:
// - The scan is shallow. It reads only the scanned files, and does not follow
//   a call into an unscanned helper. Add the helper to `scannedHelpers`.
// - It cannot tell `db` from `mainDB`, so the allowlists are kept by hand.
// - It checks for a grant of any privilege, not for the right one.
// - A table reached only through a relation or raw SQL is not named.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPAuthoringGrantCoverageTests {
    /// Every Swift file in these directories is scanned.
    private static let scannedDirectories = [
        "Sources/APIServer/MCP/Tools",
        "Sources/APIServer/MCP/Resources",
    ]

    /// Helpers outside the MCP directories that MCP tools call with
    /// `context.db`. A file that also holds web or worker code reports every
    /// table it names, so add one only when that is acceptable: today each
    /// table these name is granted.
    private static let scannedHelpers = [
        "Sources/APIServer/Services/SectionPlacement.swift",
        "Sources/APIServer/Services/AssignmentAuthoringService.swift",
        "Sources/APIServer/Helpers/ManifestFieldEdits.swift",
        "Sources/APIServer/Helpers/CourseAccessHelpers.swift",
    ]

    private struct Allowance {
        /// The scanned files that may name the table.
        let files: Set<String>
        let reason: String
    }

    /// Tables that these files name but query only on the owner pool.
    private static let ownerPoolOnly: [String: Allowance] = [
        APIAssignmentVersion.schema: Allowance(
            files: ["AssignmentVersionTools.swift", "RestoreAssignmentVersionTool.swift"],
            reason: "Version history holds secret tests and solutions. The version tools read it on ToolContext.mainDB."
        ),
        APITournamentRun.schema: Allowance(
            files: ["RunTournamentTool.swift"],
            reason:
                "run_tournament starts the run on ToolContext.mainDB: its entrants are student submissions, which the role cannot see."
        ),
    ]

    /// Tables that these files reach on `context.db` with no grant. Each one
    /// is a bug to fix by routing the call to the owner pool. Remove the entry
    /// when that is done.
    private static let knownGaps: [String: Allowance] = [:]

    private static func allowance(for table: String) -> Allowance? {
        ownerPoolOnly[table] ?? knownGaps[table]
    }

    @Test func everyNamedTableIsGranted() throws {
        let granted = try Self.grantedTables()
        for (table, files) in try Self.namedTables().sorted(by: { $0.key < $1.key })
        where !granted.contains(table) {
            let unexplained = files.subtracting(Self.allowance(for: table)?.files ?? [])
            #expect(
                unexplained.isEmpty,
                """
                \(table) is named by \(unexplained.sorted().joined(separator: ", ")) but has no GRANT in \
                deploy/sql/mcp-least-privilege-role.sql. On the dedicated MCP pool, every query on it \
                fails with permission denied. Grant it, or list the file in ownerPoolOnly if it reaches \
                the table only on ToolContext.mainDB.
                """)
        }
    }

    @Test func allowlistEntriesAreStillNeeded() throws {
        let granted = try Self.grantedTables()
        let named = try Self.namedTables()
        #expect(Set(Self.ownerPoolOnly.keys).isDisjoint(with: Self.knownGaps.keys))
        for (table, allowance) in Self.ownerPoolOnly.merging(Self.knownGaps, uniquingKeysWith: { a, _ in a }) {
            #expect(!granted.contains(table), "\(table) is allowed but also granted. Remove the entry.")
            let stale = allowance.files.subtracting(named[table] ?? [])
            #expect(stale.isEmpty, "\(table) is allowed in \(stale.sorted()), which no longer name it. Remove them.")
        }
    }

    /// A scanner that reads the wrong text passes every check above, so pin
    /// what it reads against the compiled values.
    @Test func scannerReadsTheModelsAndTheGrants() throws {
        let schemas = try Self.modelSchemas()
        #expect(schemas[String(describing: APICourseContentItem.self)] == APICourseContentItem.schema)
        #expect(schemas[String(describing: APITestSetup.self)] == APITestSetup.schema)
        #expect(schemas[String(describing: ValidationVariant.self)] == ValidationVariant.schema)

        let named = try Self.namedTables()
        #expect(named[APICourseContentItem.schema]?.contains("SectionPlacement.swift") == true)

        let granted = try Self.grantedTables()
        #expect(granted.contains(APICourse.schema))
        #expect(granted.contains(APIReflectionFeedback.schema))
        // The stopgap GRANT quoted in a comment of section 5 must not count.
        #expect(!granted.contains(APIAssignmentPersonalizationSeed.schema))
    }

    @Test func commentsDoNotCountAsUses() throws {
        let source = """
            // APICourse in a line comment
            let a = 1  // APIUser in a trailing comment
            /* APITestSetup in a
               block comment */
            let link = "https://example.org"  // APIResult after a URL
            let b = APIAssignment.query
            """
        let identifiers = try Self.codeIdentifiers(in: source)
        #expect(identifiers.isDisjoint(with: ["APICourse", "APIUser", "APITestSetup", "APIResult"]))
        #expect(identifiers.contains("APIAssignment"))
    }

    // MARK: - Scanning

    /// Model type name to table name, read from every `Model` class in
    /// `Sources/`. Each model file declares one class and one schema.
    private static func modelSchemas() throws -> [String: String] {
        let classPattern = try Regex(#"final class (\w+)[^{]*\bModel\b"#)
        let schemaPattern = try Regex(#"static (?:let|var) schema\s*=\s*"(\w+)""#)
        var schemas: [String: String] = [:]
        for file in try swiftFiles(under: repositoryRoot.appendingPathComponent("Sources")) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard let schema = source.firstMatch(of: schemaPattern)?.output[1].substring,
                let name = source.firstMatch(of: classPattern)?.output[1].substring
            else { continue }
            schemas[String(name)] = String(schema)
        }
        return schemas
    }

    /// Table name to the scanned files that name its model in code.
    private static func namedTables() throws -> [String: Set<String>] {
        let schemas = try modelSchemas()
        let directoryFiles = try scannedDirectories.flatMap {
            try swiftFiles(under: repositoryRoot.appendingPathComponent($0))
        }
        let files = directoryFiles + scannedHelpers.map { repositoryRoot.appendingPathComponent($0) }
        var named: [String: Set<String>] = [:]
        for file in files {
            let identifiers = try codeIdentifiers(in: String(contentsOf: file, encoding: .utf8))
            for (model, table) in schemas where identifiers.contains(model) {
                named[table, default: []].insert(file.lastPathComponent)
            }
        }
        return named
    }

    /// The identifiers in `source` without its comments, so prose that names
    /// a model does not count as a use of it. A line comment starts at a `//`
    /// with whitespace or nothing before it, which leaves `https://` alone.
    private static func codeIdentifiers(in source: String) throws -> Set<String> {
        let blockComment = try Regex(#"/\*[\s\S]*?\*/"#)
        let lineComment = try Regex(#"(?:^|\s)//.*"#)
        let code = source.replacing(blockComment, with: " ")
            .split(separator: "\n")
            .map { $0.replacing(lineComment, with: "") }
            .joined(separator: "\n")
        let words = code.split { !($0.isLetter || $0.isNumber || $0 == "_") }
        return Set(words.map(String.init))
    }

    /// Every table with a grant of any privilege.
    private static func grantedTables() throws -> Set<String> {
        Set(try MCPRoleGrants.privilegesByTable().keys)
    }
}
