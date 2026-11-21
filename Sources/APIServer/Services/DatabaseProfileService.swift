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
// stored jsonb exactly as read (never on a re-encoding, which a row written by
// another version of the code would not match), and writes one
// `database.configuration_changed` audit entry in the same transaction. If the
// audit entry is not written, the transaction throws and rolls back, so a
// change is never stored unrecorded. Two servers that boot together (a
// blue-green overlap) both try the update; the second matches no row, so there
// is one row and one entry. A row that differs only in shape (a field added
// since it was stored, or one that does not decode) is rewritten once, with no
// audit entry and no new "since".
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
            let missing = snapshot.missingFingerprintFields.joined(separator: ", ")
            app.logger.warning("database_profile_incomplete: no value for \(missing), so no change is recorded")
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
            localeProvider: settings?.localeProvider,
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
        var localeProvider: String?
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
                  (SELECT COALESCE(to_jsonb(d) ->> 'datlocale', to_jsonb(d) ->> 'daticulocale', d.datcollate::text)
                    FROM pg_database d WHERE d.datname = current_database()) AS collation,
                  (SELECT to_jsonb(d) ->> 'datlocprovider'
                    FROM pg_database d WHERE d.datname = current_database()) AS locale_provider,
                  current_user::text AS role_name
                """
            ).first()
        } catch {
            db.logger.warning("database_profile_settings_read_failed: \(String(reflecting: error))")
            return nil
        }
        guard let row else { return nil }
        // The locale columns differ by version, so they are read through
        // `to_jsonb`, which gives NULL for a column the version lacks instead
        // of failing the statement: `datlocale` (17+), `daticulocale` (15 and
        // 16), `datlocprovider` (15+). With the ICU or builtin provider the
        // effective locale is `datlocale`, and `datcollate` only names the
        // libc fallback.
        var nullColumns: [String] = []
        func text(_ column: String) -> String? {
            let value = try? row.decode(column: column, as: String?.self)
            if value == nil { nullColumns.append(column) }
            return value
        }
        defer {
            // A NULL or undecodable value, as against a failed read: name it,
            // because it leaves the fingerprint nil.
            if !nullColumns.isEmpty {
                db.logger.warning("database_profile_setting_null: \(nullColumns.joined(separator: ", "))")
            }
        }
        return Settings(
            serverVersion: text("server_version"),
            serverVersionNumber: text("server_version_num").flatMap { Int($0) },
            dataChecksums: text("data_checksums").flatMap(onOff),
            maxConnections: text("max_connections").flatMap { Int($0) },
            serverEncoding: text("server_encoding"),
            collation: text("collation"),
            localeProvider: text("locale_provider").map(localeProviderName),
            role: text("role_name"))
    }

    /// `datlocprovider` as a word: "libc", "icu", "builtin", or the raw code.
    private static func localeProviderName(_ code: String) -> String {
        switch code {
        case "c": return "libc"
        case "i": return "icu"
        case "b": return "builtin"
        default: return code
        }
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
    /// the row as it stands afterwards. A change writes one audit entry, or
    /// throws and stores nothing. `auditDatabase` wraps the transaction the
    /// audit entry is written on; only a test passes it, to make that write
    /// fail.
    @discardableResult
    static func record(
        _ fingerprint: DatabaseFingerprint, now: Date = Date(), app: Application,
        auditDatabase: (@Sendable (any Database) -> any Database)? = nil
    ) async throws -> DatabaseProfileRecord {
        guard let sql = app.db as? (any SQLDatabase) else { throw DatabaseProfileError.notSQL }
        guard let newJSON = fingerprint.jsonText else { throw DatabaseProfileError.unencodableFingerprint }
        guard let stored = try await readStored(on: sql) else {
            // First reading: insert, first insert wins. Nothing to compare
            // with, so no audit entry.
            try await DatabaseProfileRecord(fingerprint: fingerprint, since: now).createIgnoringConflict(on: app.db)
            return try await readStored(on: sql)?.record ?? DatabaseProfileRecord(fingerprint: fingerprint, since: now)
        }
        guard stored.fingerprint != fingerprint else { return stored.fallback(fingerprint) }

        let changes = stored.fingerprint.map { fingerprint.changes(from: $0) } ?? []
        guard let old = stored.fingerprint, !changes.isEmpty else {
            // Only the shape differs: a field added since the row was
            // stored, or a row that does not decode. Rewrite it once, keyed
            // on the raw value, with no audit entry and the same "since".
            if stored.fingerprint == nil {
                app.logger.warning("database_profile_unreadable: the stored fingerprint does not decode; replacing it")
            }
            try await sql.raw(
                """
                UPDATE \(ident: DatabaseProfileRecord.schema) SET fingerprint_json = \(bind: newJSON)::jsonb
                WHERE key = \(bind: DatabaseProfileRecord.currentKey)
                  AND fingerprint_json = \(bind: stored.rawJSON)::jsonb
                """
            ).run()
            return try await readStored(on: sql)?.record ?? stored.fallback(fingerprint)
        }

        try await app.db.transaction { tx in
            guard let txSQL = tx as? (any SQLDatabase) else { throw DatabaseProfileError.notSQL }
            // Compare-and-set on the stored value exactly as read. A server
            // that lost the race to the same change matches no row.
            let updated = try await txSQL.raw(
                """
                UPDATE \(ident: DatabaseProfileRecord.schema)
                SET fingerprint_json = \(bind: newJSON)::jsonb, previous_json = fingerprint_json, since = \(bind: now)
                WHERE key = \(bind: DatabaseProfileRecord.currentKey)
                  AND fingerprint_json = \(bind: stored.rawJSON)::jsonb
                RETURNING key
                """
            ).all()
            guard !updated.isEmpty else { return }
            // `record` would swallow a failed insert. On Postgres that leaves
            // the transaction aborted, and COMMIT then rolls it back without
            // an error, so the change would vanish unrecorded. Throw instead:
            // the transaction rolls back visibly and `observe` logs it.
            let entry = await AuditLogger.recordReturning(
                action: .databaseConfigurationChanged,
                targetType: .deployment,
                metadata: fingerprint.auditMetadata(from: old),
                on: SystemAuditContext(db: auditDatabase?(tx) ?? tx, application: app))
            guard entry != nil else { throw DatabaseProfileError.auditEntryNotWritten }
        }
        return try await readStored(on: sql)?.record ?? stored.fallback(fingerprint)
    }

    /// The stored row as read: the raw `fingerprint_json` text for the
    /// compare-and-set, and what it decodes to.
    private struct StoredProfile {
        let rawJSON: String
        /// Nil when the stored JSON does not decode.
        let fingerprint: DatabaseFingerprint?
        let previous: DatabaseFingerprint?
        let since: Date

        /// The row as a record, or nil when its fingerprint does not decode.
        var record: DatabaseProfileRecord? {
            guard let fingerprint else { return nil }
            let record = DatabaseProfileRecord(fingerprint: fingerprint, since: since)
            record.previous = previous
            return record
        }

        /// A record for `fingerprint` when the row cannot be read back.
        func fallback(_ fingerprint: DatabaseFingerprint) -> DatabaseProfileRecord {
            record ?? DatabaseProfileRecord(fingerprint: fingerprint, since: since)
        }
    }

    private static func readStored(on sql: any SQLDatabase) async throws -> StoredProfile? {
        guard
            let row = try await sql.raw(
                """
                SELECT fingerprint_json::text AS fingerprint, previous_json::text AS previous, since
                FROM \(ident: DatabaseProfileRecord.schema) WHERE key = \(bind: DatabaseProfileRecord.currentKey)
                """
            ).first()
        else { return nil }
        let raw = try row.decode(column: "fingerprint", as: String.self)
        let previous = try row.decode(column: "previous", as: String?.self)
        return StoredProfile(
            rawJSON: raw,
            fingerprint: DatabaseFingerprint.decode(jsonText: raw),
            previous: previous.flatMap(DatabaseFingerprint.decode(jsonText:)),
            since: try row.decode(column: "since", as: Date.self))
    }
}

/// Why a database-configuration change could not be recorded.
enum DatabaseProfileError: Error, Equatable {
    /// A fingerprint did not encode to JSON for the compare-and-set.
    case unencodableFingerprint
    /// The database is not SQL, so the compare-and-set cannot run.
    case notSQL
    /// The change's audit entry was not written, so the change was rolled
    /// back.
    case auditEntryNotWritten
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
