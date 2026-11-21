// APIServer/Services/DatabaseFingerprint.swift
//
// The database configuration values the admin Overview tracks for change
// (`DatabaseProfileService`). Stored as jsonb in `database_profile`. It holds
// no credential, host or role name: the MCP pool is one yes/no.
//
// Evolution. A stored row outlives the code that wrote it, so the decoder
// ignores a key it does not know, and a field added after the first release
// is optional: a row stored before it decodes with nil. A nil value is "not
// tracked then", so it is never reported as a change
// (`changes(from:)`); `DatabaseProfileService.record` rewrites such a row
// once, with no audit entry. Add a new field as an optional, never as a
// required one.

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
    /// The database's effective locale: `datlocale` (ICU or builtin,
    /// PostgreSQL 17+), `daticulocale` (ICU, 15 and 16) or `datcollate`.
    let collation: String
    /// Whether the MCP pool connects as a role other than the main pool's.
    let mcpPoolSeparateRole: Bool
    /// The locale provider: "libc", "icu" or "builtin". Added after the first
    /// release, so optional (see Evolution above).
    var localeProvider: String?

    init(
        serverVersion: String, dataChecksums: Bool, maxConnections: Int, statStatementsLoaded: Bool,
        serverEncoding: String, collation: String, mcpPoolSeparateRole: Bool, localeProvider: String? = nil
    ) {
        self.serverVersion = serverVersion
        self.dataChecksums = dataChecksums
        self.maxConnections = maxConnections
        self.statStatementsLoaded = statStatementsLoaded
        self.serverEncoding = serverEncoding
        self.collation = collation
        self.mcpPoolSeparateRole = mcpPoolSeparateRole
        self.localeProvider = localeProvider
    }

    /// One tracked value: a stable key (the audit metadata key), a label and
    /// its display text.
    struct Field: Sendable, Equatable {
        let key: String
        let label: String
        /// Nil for an optional field that was not tracked when stored.
        let value: String?
    }

    /// One tracked value that differs between two fingerprints.
    struct Change: Sendable, Equatable {
        let key: String
        let label: String
        let old: String
        let new: String

        /// The label as it reads inside a sentence: "max connections", but
        /// "PostgreSQL" and "MCP pool" keep their capitals.
        var labelInSentence: String {
            guard let first = label.first, first.isUppercase else { return label }
            let firstWord = label.prefix { $0 != " " }
            if firstWord.dropFirst().contains(where: \.isUppercase) { return label }
            return first.lowercased() + label.dropFirst()
        }
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
            Field(key: "locale_provider", label: "Locale provider", value: localeProvider),
        ]
    }

    /// The values that differ from `old`, in display order. A field that is
    /// nil on either side was not tracked then, so it is not a change.
    func changes(from old: DatabaseFingerprint) -> [Change] {
        zip(old.fields, fields).compactMap { before, after in
            guard let oldValue = before.value, let newValue = after.value, oldValue != newValue else { return nil }
            return Change(key: after.key, label: after.label, old: oldValue, new: newValue)
        }
    }

    /// Decodes a stored `fingerprint_json` text, or nil when it does not
    /// decode (a required key is missing or has the wrong type).
    static func decode(jsonText: String) -> DatabaseFingerprint? {
        try? JSONDecoder().decode(DatabaseFingerprint.self, from: Data(jsonText.utf8))
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
