// Tests/APITests/MigrationSourceScan.swift
//
// Reads table names out of migration sources for the order and
// user-reference scans (#2280). A migration names its table in one of three
// ways: `schema("table")`, `schema(Model.schema)`, or raw `ALTER TABLE
// table`. A scan that read only the first missed every migration written in
// the other two shapes.

import Foundation

enum MigrationSourceScan {

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // APITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    /// A `schema(...)` call: the literal table name is capture 1, the model
    /// name is capture 2.
    static var schemaCall: Regex<(Substring, Substring?, Substring?)> {
        #/\.schema\((?:"([a-z_]+)"|([A-Za-z]+)\.schema)\)/#
    }

    /// The table a model declares with `static let schema`, or nil when the
    /// model has no file of its name or declares no schema there.
    static func table(ofModel model: String) -> String? {
        let url = repoRoot.appendingPathComponent("Sources/APIServer/Models/\(model).swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return source.firstMatch(of: #/static let schema = "([a-z_]+)"/#).map { String($0.output.1) }
    }

    /// The table one `schemaCall` match names.
    static func table(of match: Regex<(Substring, Substring?, Substring?)>.Match) -> String? {
        if let literal = match.output.1 { return String(literal) }
        return match.output.2.flatMap { table(ofModel: String($0)) }
    }

    /// Every table a migration source names, in any of the three shapes.
    /// Throws when a `schema(Model.schema)` names a model whose table cannot
    /// be read, so a scan never skips a migration silently.
    static func tables(in source: String) throws -> Set<String> {
        var tables: Set<String> = []
        for match in source.matches(of: schemaCall) {
            guard let table = table(of: match) else {
                throw ScanError.unresolvedModel(String(match.output.0))
            }
            tables.insert(table)
        }
        for match in source.matches(of: #/ALTER TABLE ([a-z_]+)/#.ignoresCase()) {
            tables.insert(String(match.output.1))
        }
        return tables
    }

    enum ScanError: Error, CustomStringConvertible {
        case unresolvedModel(String)

        var description: String {
            switch self {
            case .unresolvedModel(let call): "cannot read the table that \(call) names"
            }
        }
    }
}
