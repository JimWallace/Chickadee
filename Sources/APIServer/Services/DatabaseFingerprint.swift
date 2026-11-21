// APIServer/Services/DatabaseFingerprint.swift
//
// The database configuration values the admin Overview tracks for change
// (`DatabaseProfileService`). Stored as jsonb in `database_profile`. It holds
// no credential, host or role name: the MCP pool is one yes/no.

import Foundation

/// The tracked database configuration. Two servers that read the same
/// database compute the same value, so a blue-green overlap records nothing.
struct DatabaseFingerprint: Codable, Sendable, Equatable {
    /// `server_version`, for example "16.4 (Debian 16.4-1.pgdg120+1)". A
    /// minor update changes it too, which is a change worth seeing.
    let serverVersion: String
    let dataChecksums: Bool
    let maxConnections: Int
    let statStatementsLoaded: Bool
    let serverEncoding: String
    let collation: String
    /// Whether the MCP pool connects as a role other than the main pool's.
    let mcpPoolSeparateRole: Bool

    /// One tracked value: a stable key (the audit metadata key), a label and
    /// its display text.
    struct Field: Sendable, Equatable {
        let key: String
        let label: String
        let value: String
    }

    /// One tracked value that differs between two fingerprints.
    struct Change: Sendable, Equatable {
        let key: String
        let label: String
        let old: String
        let new: String
    }

    /// Every tracked value, in display order.
    var fields: [Field] {
        [
            Field(key: "server_version", label: "PostgreSQL", value: serverVersion),
            Field(key: "data_checksums", label: "Data checksums", value: Self.onOff(dataChecksums)),
            Field(key: "max_connections", label: "Max connections", value: String(maxConnections)),
            Field(
                key: "pg_stat_statements", label: "pg_stat_statements",
                value: statStatementsLoaded ? "loaded" : "not loaded"),
            Field(key: "server_encoding", label: "Encoding", value: serverEncoding),
            Field(key: "collation", label: "Collation", value: collation),
            Field(
                key: "mcp_pool_separate_role", label: "MCP pool",
                value: mcpPoolSeparateRole ? "separate role" : "no separate role"),
        ]
    }

    /// The values that differ from `old`, in display order.
    func changes(from old: DatabaseFingerprint) -> [Change] {
        zip(old.fields, fields).compactMap { before, after in
            before.value == after.value
                ? nil : Change(key: after.key, label: after.label, old: before.value, new: after.value)
        }
    }

    /// The audit metadata for a change from `old`: the changed keys, and
    /// "old → new" under each one.
    func auditMetadata(from old: DatabaseFingerprint) -> [String: String] {
        let changes = changes(from: old)
        var metadata = ["changed": changes.map(\.key).joined(separator: ", ")]
        for change in changes {
            metadata[change.key] = "\(change.old) → \(change.new)"
        }
        return metadata
    }

    /// The fingerprint as compact JSON with sorted keys, for a bound
    /// `jsonb` comparison. Nil only if encoding fails, which a struct of
    /// strings, numbers and booleans does not.
    var jsonText: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }
}
