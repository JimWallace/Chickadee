// APIServer/Bootstrap/LegacyMigrationNamespaceGuard.swift
//
// Refuses to boot on a database whose migration history was written under a
// module-derived namespace, the mark of a Chickadee v0.4.200 or earlier
// (#2282).

import Fluent
import Vapor

// Namespaces produced by older builds, before `ChickadeeMigration` pinned
// migration names to "chickadee.*":
//   - "chickadee_server." — when the server code was the `chickadee-server`
//     executable module (≤ v0.4.172-ish).
//   - "APIServer."        — after `APIServer` was split into its own library
//     target, but before the names were pinned (v0.4.198–0.4.200).
private let legacyMigrationPrefixes = ["chickadee_server.", "APIServer."]

/// Why the server will not start on this database.
struct LegacyMigrationNamespaceError: Error, CustomStringConvertible {
    let legacyRows: Int
    let example: String

    var description: String {
        """
        This database records \(legacyRows) migration(s) under a module name that only \
        Chickadee v0.4.200 or earlier used (for example \(example)). Every consolidation round \
        since then folded migrations into their Create* files, so this build cannot add the \
        columns this database is missing. Restore a backup taken by a newer release.
        """
    }
}

/// Throws `LegacyMigrationNamespaceError` when `_fluent_migrations` holds a
/// row under a legacy namespace.
///
/// This used to rename those rows to "chickadee.*" so `autoMigrate` would see
/// them as applied. That stopped being enough once the consolidation rounds
/// folded later migrations into the `Create*` files: a renamed `CreateUsers`
/// counts as applied, the columns folded into it are never added, and the
/// first query on the model fails after a boot that looked clean. A loud stop
/// at startup names the problem instead.
///
/// Runs after `registerMigrations` and before `autoMigrate`. A brand-new
/// database has no `_fluent_migrations` table yet; a failed read means there
/// is no history to check.
func refuseLegacyMigrationNamespace(on app: Application) throws {
    let logs: [MigrationLog]
    do {
        logs = try MigrationLog.query(on: app.db).all().wait()
    } catch {
        app.logger.debug(
            "Skipping the legacy migration-namespace check (no _fluent_migrations table yet?): \(String(reflecting: error))"
        )
        return
    }
    let legacy = logs.map(\.name).filter { name in legacyMigrationPrefixes.contains { name.hasPrefix($0) } }
    guard let example = legacy.min() else { return }
    throw LegacyMigrationNamespaceError(legacyRows: legacy.count, example: example)
}
