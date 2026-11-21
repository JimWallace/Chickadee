// APIServer/Services/DatabaseProfileService.swift
//
// The live database configuration for the admin Overview's Database card and
// the admin MCP tool `get_deployment_info`, and the record of when it changed
// (for example after a PostgreSQL major upgrade).
//
// Reads. One row of settings (`server_version`, `data_checksums`,
// `max_connections`, `server_encoding`, the database's collation and the
// main pool's role), the database size (`databaseSizeBytes`), whether
// `pg_stat_statements` is preloaded (`QueryStatistics.availability`) and, when
// a dedicated MCP pool is configured, that pool's role. Each read fails on its
// own into a nil field, which the card shows as "unavailable"; nothing here
// throws to a page. Role names are compared, never kept.
//
// Change tracking. When every tracked value was read, the reading's
// `DatabaseFingerprint` is compared with the one row in `database_profile`.
// The first reading inserts the row, first insert wins, with no audit entry.
// A different reading replaces it with a compare-and-set update keyed on the
// old fingerprint, and writes one `database.configuration_changed` audit entry
// in the same transaction. Two servers that boot together (a blue-green
// overlap) both try the update; the second matches no row, so there is one
// row and one entry.
//
// When. At boot (`bootstrapAppServices`), and on an Overview render or a
// cache miss after that: the reading is cached for a minute
// (`SingleFlightCache`), so the Overview pays for it at most once a minute and
// a change made while the server runs is still seen.

import Fluent
import Foundation
import SQLKit
import Vapor

enum DatabaseProfileService {
    /// How long a reading is served before the next one.
    static let cacheTTL: TimeInterval = 60

    /// The cached reading, or a fresh one (which records a change) when the
    /// cache is older than `cacheTTL`. Never throws.
    static func snapshot(app: Application) async -> DatabaseProfileSnapshot {
        let cached = try? await app.databaseProfileCache.value { await observe(app: app) }
        return cached ?? DatabaseProfileSnapshot(mcpPool: .unavailable, observedAt: Date())
    }

    /// The newest cached reading, with no database access: nil before the
    /// first one. `get_deployment_info` must answer when the database is down.
    static func latestSnapshot(app: Application) async -> DatabaseProfileSnapshot? {
        await app.databaseProfileCache.latest()
    }

    /// Reads the configuration and records a change.
    static func observe(app: Application, now: Date = Date()) async -> DatabaseProfileSnapshot {
        var snapshot = await read(app: app, now: now)
        guard let fingerprint = snapshot.fingerprint else {
            app.logger.warning("database_profile_incomplete: a read failed, so no change is recorded")
            return snapshot
        }
        do {
            let stored = try await record(fingerprint, now: now, app: app)
            snapshot.since = stored.since
            snapshot.previousChanges = stored.previous.map { stored.fingerprint.changes(from: $0) } ?? []
        } catch {
            app.logger.error("database_profile_record_failed: \(String(reflecting: error))")
        }
        return snapshot
    }

    // MARK: - Reads

    /// One reading. Each failed read leaves its fields nil.
    static func read(app: Application, now: Date = Date()) async -> DatabaseProfileSnapshot {
        let settings = await readSettings(on: app.db)
        let size = await databaseSizeBytes(on: app.db)
        let availability = try? await QueryStatistics.availability(on: app.db)
        let mcpPool = await mcpPoolState(app: app, mainRole: settings?.role)
        return DatabaseProfileSnapshot(
            serverVersion: settings?.serverVersion,
            serverVersionNumber: settings?.serverVersionNumber,
            dataChecksums: settings?.dataChecksums,
            maxConnections: settings?.maxConnections,
            statStatementsLoaded: availability.map { $0 != .notPreloaded },
            serverEncoding: settings?.serverEncoding,
            collation: settings?.collation,
            sizeBytes: size,
            mcpPool: mcpPool,
            observedAt: now)
    }

    /// The settings row. A column that does not decode is nil on its own.
    private struct Settings {
        var serverVersion: String?
        var serverVersionNumber: Int?
        var dataChecksums: Bool?
        var maxConnections: Int?
        var serverEncoding: String?
        var collation: String?
        var role: String?
    }

    private static func readSettings(on db: any Database) async -> Settings? {
        guard let sql = db as? (any SQLDatabase) else { return nil }
        let row: (any SQLRow)?
        do {
            row = try await sql.raw(
                """
                SELECT current_setting('server_version') AS server_version,
                  current_setting('server_version_num') AS server_version_num,
                  current_setting('data_checksums') AS data_checksums,
                  current_setting('max_connections') AS max_connections,
                  current_setting('server_encoding') AS server_encoding,
                  (SELECT datcollate::text FROM pg_database WHERE datname = current_database()) AS collation,
                  current_user::text AS role_name
                """
            ).first()
        } catch {
            db.logger.warning("database_profile_settings_read_failed: \(String(reflecting: error))")
            return nil
        }
        guard let row else { return nil }
        func text(_ column: String) -> String? {
            try? row.decode(column: column, as: String?.self)
        }
        return Settings(
            serverVersion: text("server_version"),
            serverVersionNumber: text("server_version_num").flatMap { Int($0) },
            dataChecksums: text("data_checksums").flatMap(onOff),
            maxConnections: text("max_connections").flatMap { Int($0) },
            serverEncoding: text("server_encoding"),
            collation: text("collation"),
            role: text("role_name"))
    }

    /// `on` / `off` as a Bool, nil for anything else.
    private static func onOff(_ value: String) -> Bool? {
        switch value {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// Whether the MCP pool is configured and connects as its own role.
    private static func mcpPoolState(app: Application, mainRole: String?) async -> DatabaseMCPPoolState {
        guard let mcpID = app.mcpDatabaseID else { return .shared }
        guard let mainRole, let sql = app.db(mcpID) as? (any SQLDatabase) else { return .unavailable }
        do {
            let row = try await sql.raw("SELECT current_user::text AS role_name").first()
            guard let mcpRole = try row?.decode(column: "role_name", as: String.self) else { return .unavailable }
            return mcpRole == mainRole ? .sameRole : .separateRole
        } catch {
            app.logger.warning("database_profile_mcp_pool_read_failed: \(String(reflecting: error))")
            return .unavailable
        }
    }

    // MARK: - Change tracking

    /// Stores `fingerprint` when it differs from the stored one, and returns
    /// the row as it stands afterwards. A change writes one audit entry.
    @discardableResult
    static func record(
        _ fingerprint: DatabaseFingerprint, now: Date = Date(), app: Application
    ) async throws -> DatabaseProfileRecord {
        let db = app.db
        guard let stored = try await DatabaseProfileRecord.find(DatabaseProfileRecord.currentKey, on: db) else {
            // First reading: insert, first insert wins. Nothing to compare
            // with, so no audit entry.
            try await DatabaseProfileRecord(fingerprint: fingerprint, since: now).createIgnoringConflict(on: db)
            return try await current(on: db, fallback: DatabaseProfileRecord(fingerprint: fingerprint, since: now))
        }
        guard stored.fingerprint != fingerprint else { return stored }

        let old = stored.fingerprint
        guard let newJSON = fingerprint.jsonText, let oldJSON = old.jsonText else {
            throw DatabaseProfileError.unencodableFingerprint
        }
        try await db.transaction { tx in
            guard let sql = tx as? (any SQLDatabase) else { return }
            // Compare-and-set on the fingerprint this server read. A server
            // that lost the race to the same change matches no row.
            let updated = try await sql.raw(
                """
                UPDATE \(ident: DatabaseProfileRecord.schema)
                SET fingerprint_json = \(bind: newJSON)::jsonb, previous_json = fingerprint_json, since = \(bind: now)
                WHERE key = \(bind: DatabaseProfileRecord.currentKey) AND fingerprint_json = \(bind: oldJSON)::jsonb
                RETURNING key
                """
            ).all()
            guard !updated.isEmpty else { return }
            await AuditLogger.record(
                action: .databaseConfigurationChanged,
                targetType: .deployment,
                metadata: fingerprint.auditMetadata(from: old),
                on: SystemAuditContext(db: tx, application: app))
        }
        return try await current(on: db, fallback: stored)
    }

    /// The stored row, or `fallback` when it cannot be read back.
    private static func current(
        on db: any Database, fallback: DatabaseProfileRecord
    ) async throws -> DatabaseProfileRecord {
        try await DatabaseProfileRecord.find(DatabaseProfileRecord.currentKey, on: db) ?? fallback
    }
}

/// Why a database-configuration change could not be recorded.
enum DatabaseProfileError: Error, Equatable {
    /// A fingerprint did not encode to JSON for the compare-and-set.
    case unencodableFingerprint
}

// MARK: - Cache

private struct DatabaseProfileCacheKey: StorageKey {
    typealias Value = SingleFlightCache<DatabaseProfileSnapshot>
}

extension Application {
    /// The newest database-configuration reading, shared by the Overview and
    /// `get_deployment_info`.
    var databaseProfileCache: SingleFlightCache<DatabaseProfileSnapshot> {
        lazyStored(DatabaseProfileCacheKey.self) {
            SingleFlightCache(ttl: DatabaseProfileService.cacheTTL)
        }
    }
}
