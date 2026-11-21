// APIServer/Services/DatabaseProfileSnapshot.swift
//
// One reading of the live database configuration, for the admin Overview's
// Database card and the admin MCP tool `get_deployment_info`. A nil field is
// a read that failed: the card shows it as "unavailable". It holds no
// password, host, connection URL or role name.

import Foundation

/// How the MCP path connects to the database.
enum DatabaseMCPPoolState: String, Sendable, Equatable {
    /// No dedicated pool: MCP shares the main pool.
    case shared
    /// A dedicated pool that connects as a different role.
    case separateRole = "separate_role"
    /// A dedicated pool that connects as the main pool's own role.
    case sameRole = "same_role"
    /// A dedicated pool is configured, but a role read failed.
    case unavailable

    /// Whether a dedicated pool is configured.
    var isConfigured: Bool { self != .shared }

    /// Whether it connects as its own role, or nil when that is unknown.
    var isSeparateRole: Bool? {
        switch self {
        case .shared, .sameRole: return false
        case .separateRole: return true
        case .unavailable: return nil
        }
    }
}

struct DatabaseProfileSnapshot: Sendable, Equatable {
    var serverVersion: String?
    /// `server_version_num`, for example 160004.
    var serverVersionNumber: Int?
    var dataChecksums: Bool?
    var maxConnections: Int?
    /// Whether Postgres preloaded `pg_stat_statements`
    /// (`QueryStatistics.availability` is not `.notPreloaded`).
    var statStatementsLoaded: Bool?
    var serverEncoding: String?
    /// The effective locale (`DatabaseFingerprint.collation`).
    var collation: String?
    /// "libc", "icu" or "builtin"; nil when it was not read.
    var localeProvider: String?
    var sizeBytes: Int?
    var mcpPool: DatabaseMCPPoolState
    /// When the stored configuration was first seen; nil when none is stored.
    var since: Date?
    /// The values that differ from the configuration before the stored one.
    var previousChanges: [DatabaseFingerprint.Change] = []
    /// When this reading was taken.
    var observedAt: Date

    /// The major version, for example 16.
    var majorVersion: Int? {
        serverVersionNumber.map { $0 / 10_000 }
    }

    /// The tracked values, or nil when any of them could not be read: a
    /// partial reading must not record a change that did not happen.
    var fingerprint: DatabaseFingerprint? {
        guard let serverVersion, let dataChecksums, let maxConnections, let statStatementsLoaded,
            let serverEncoding, let collation, let separate = mcpPool.isSeparateRole
        else { return nil }
        return DatabaseFingerprint(
            serverVersion: serverVersion, dataChecksums: dataChecksums, maxConnections: maxConnections,
            statStatementsLoaded: statStatementsLoaded, serverEncoding: serverEncoding, collation: collation,
            mcpPoolSeparateRole: separate, localeProvider: localeProvider)
    }

    /// The tracked values that have no value, by their fingerprint key: why
    /// `fingerprint` is nil.
    var missingFingerprintFields: [String] {
        let present: [(key: String, isPresent: Bool)] = [
            ("server_version", serverVersion != nil), ("data_checksums", dataChecksums != nil),
            ("max_connections", maxConnections != nil), ("pg_stat_statements", statStatementsLoaded != nil),
            ("server_encoding", serverEncoding != nil), ("collation", collation != nil),
            ("mcp_pool_separate_role", mcpPool.isSeparateRole != nil),
        ]
        return present.filter { !$0.isPresent }.map(\.key)
    }
}
