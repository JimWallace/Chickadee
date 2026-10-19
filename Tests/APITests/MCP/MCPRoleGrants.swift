// Tests/APITests/MCP/MCPRoleGrants.swift
//
// The grants that deploy/sql/mcp-least-privilege-role.sql gives the
// `chickadee_mcp` role, for the suites that check them. Two suites used to
// parse the file each in its own way, and one of them read only statements
// that grant SELECT alone.

import ChickadeeTestSupport
import Foundation

enum MCPRoleGrants {
    static var file: URL {
        repositoryRoot.appendingPathComponent("deploy/sql/mcp-least-privilege-role.sql")
    }

    /// Table name to the privileges granted on it, in upper case. A column
    /// grant keeps its column list, as `SELECT (id,kind)`, so it never counts
    /// as the table-level `SELECT`. A grant on a schema is not a table and is
    /// left out.
    ///
    /// SQL comments are removed first: section 5 quotes a stopgap GRANT that
    /// must stay revoked. `REVOKE` is not read, because the file issues none.
    static func privilegesByTable() throws -> [String: Set<String>] {
        try privilegesByTable(in: String(contentsOf: file, encoding: .utf8))
    }

    static func privilegesByTable(in sql: String) throws -> [String: Set<String>] {
        let statements = sql.split(separator: "\n")
            .map { line in line.range(of: "--").map { line[..<$0.lowerBound] } ?? line }
            .joined(separator: " ")
        let grantPattern = try Regex(#"GRANT\s+([A-Z_, ()]+?)\s+ON\s+([^;]+?)\s+TO\s+chickadee_mcp"#).ignoresCase()
        let privilegePattern = try Regex(#"([A-Z_]+)\s*(\([^)]*\))?"#).ignoresCase()
        var grants: [String: Set<String>] = [:]
        for match in statements.matches(of: grantPattern) {
            guard let privilegeList = match.output[1].substring, let targetList = match.output[2].substring
            else { continue }
            let privileges = privilegeList.matches(of: privilegePattern).compactMap { privilege -> String? in
                guard let name = privilege.output[1].substring?.uppercased() else { return nil }
                guard let columns = privilege.output[2].substring else { return name }
                return name + " " + columns.filter { !$0.isWhitespace }
            }
            for target in targetList.split(separator: ",") {
                let table = target.trimmingCharacters(in: .whitespaces)
                guard !table.uppercased().hasPrefix("SCHEMA ") else { continue }
                grants[table, default: []].formUnion(privileges)
            }
        }
        return grants
    }
}
