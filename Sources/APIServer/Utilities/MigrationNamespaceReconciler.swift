// APIServer/Utilities/MigrationNamespaceReconciler.swift
//
// One-time, idempotent reconciliation of Fluent migration-history rows written
// under the server's previous Swift module name. See the doc comment on
// `reconcileLegacyMigrationNamespace`.

import Fluent
import Vapor

// The server code lived in the `chickadee-server` executable module before
// `APIServer` was extracted into its own library target; Swift sanitizes the
// dash, so the old module name is `chickadee_server`.
private let legacyMigrationModulePrefix = "chickadee_server."

/// Rewrites `_fluent_migrations` rows from the legacy module namespace
/// (`chickadee_server.*`) to the build's current module namespace, so a database
/// produced by a pre-rename build (e.g. a restored v0.4.172 prod snapshot)
/// migrates cleanly instead of re-running already-applied migrations.
///
/// Fluent identifies a migration by its module-qualified type name
/// (`"<module>.<Type>"`). When `APIServer` was split into its own target the
/// module name changed, so every one of our migration identifiers changed with
/// it. A DB created by the old build records `chickadee_server.CreateUsers`; the
/// current build looks for `APIServer.CreateUsers`, decides it is unapplied,
/// re-runs `CreateUsers`, and collides with the existing `users` table (Postgres
/// 42P07), crash-looping the server on boot.
///
/// Must run AFTER `registerMigrations` and BEFORE `autoMigrate` — that's where
/// applied/unapplied state is evaluated. Idempotent: a no-op when there are no
/// legacy rows (the normal case) and on a fresh database where the
/// `_fluent_migrations` table does not exist yet.
func reconcileLegacyMigrationNamespace(on app: Application) throws {
    // Derive the current module prefix from a known migration type, so this keeps
    // working if the module is ever renamed again. Fluent's default migration
    // name is the module-qualified type name, e.g. "APIServer.CreateUsers".
    let currentModule = String(String(reflecting: CreateUsers.self).prefix { $0 != "." })
    let currentPrefix = currentModule + "."
    guard currentPrefix != legacyMigrationModulePrefix else { return }

    // `_fluent_migrations` may not exist yet on a brand-new database (autoMigrate
    // creates it). A failed read means there's nothing to reconcile.
    let logs: [MigrationLog]
    do {
        logs = try MigrationLog.query(on: app.db).all().wait()
    } catch {
        app.logger.debug(
            "Skipping migration-namespace reconcile (no _fluent_migrations table yet?): \(String(reflecting: error))"
        )
        return
    }

    let existingNames = Set(logs.map(\.name))
    var renamed = 0
    var dropped = 0
    for log in logs where log.name.hasPrefix(legacyMigrationModulePrefix) {
        let canonical = currentPrefix + String(log.name.dropFirst(legacyMigrationModulePrefix.count))
        if existingNames.contains(canonical) {
            // The canonical row is already present — drop the duplicate legacy
            // row rather than rename it into a name collision.
            try log.delete(force: true, on: app.db).wait()
            dropped += 1
        } else {
            log.name = canonical
            try log.save(on: app.db).wait()
            renamed += 1
        }
    }

    guard renamed > 0 || dropped > 0 else { return }
    app.logger.notice(
        "Reconciled legacy migration namespace '\(legacyMigrationModulePrefix)' -> '\(currentPrefix)': \(renamed) renamed, \(dropped) duplicate(s) removed"
    )
}
