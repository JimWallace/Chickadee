// APIServer/Utilities/MigrationNamespaceReconciler.swift
//
// One-time, idempotent reconciliation of Fluent migration-history rows written
// under a previous, module-derived migration namespace. See the doc comment on
// `reconcileLegacyMigrationNamespace`.

import Fluent
import Vapor

// Canonical, module-independent namespace produced by `ChickadeeMigration`
// (e.g. "chickadee.CreateUsers"). All of our migrations record under this now.
private let canonicalMigrationPrefix = "chickadee."

// Namespaces produced by older builds, before migration names were pinned:
//   - "chickadee_server." — when the server code was the `chickadee-server`
//     executable module (≤ v0.4.172-ish).
//   - "APIServer."        — after `APIServer` was split into its own library
//     target, but before `ChickadeeMigration` pinned the names (v0.4.198–0.4.200).
// Both used Fluent's default `String(reflecting: Self.self)` identifier.
private let legacyMigrationPrefixes = ["chickadee_server.", "APIServer."]

/// Rewrites `_fluent_migrations` history rows from any legacy, module-derived
/// namespace to the canonical `chickadee.*` namespace, so a database produced by
/// an older build (e.g. a restored pre-rename prod snapshot) migrates cleanly
/// instead of re-running already-applied migrations.
///
/// Fluent identifies a migration by `name`, which defaulted to the
/// module-qualified type name (`"<module>.<Type>"`). Renaming/splitting the
/// module therefore changed every identifier, so the new build saw the old
/// history as unapplied, re-ran `CreateUsers`, and collided with the existing
/// `users` table (Postgres 42P07), crash-looping on boot. `ChickadeeMigration`
/// now pins names to a module-independent form; this step migrates databases
/// still carrying a legacy namespace onto it.
///
/// Must run AFTER `registerMigrations` and BEFORE `autoMigrate` — that's where
/// applied/unapplied state is evaluated. Idempotent: a no-op when there are no
/// legacy rows (the normal case) and on a fresh database where the
/// `_fluent_migrations` table does not exist yet.
func reconcileLegacyMigrationNamespace(on app: Application) throws {
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

    var existingNames = Set(logs.map(\.name))
    var renamed = 0
    var dropped = 0
    for log in logs {
        guard let legacy = legacyMigrationPrefixes.first(where: { log.name.hasPrefix($0) }) else {
            continue
        }
        let canonical = canonicalMigrationPrefix + String(log.name.dropFirst(legacy.count))
        if existingNames.contains(canonical) {
            // A canonical row already exists (a fresh row, or another legacy
            // namespace already mapped here) — drop the duplicate legacy row
            // rather than rename it into a name collision.
            try log.delete(force: true, on: app.db).wait()
            dropped += 1
        } else {
            log.name = canonical
            try log.save(on: app.db).wait()
            existingNames.insert(canonical)
            renamed += 1
        }
    }

    guard renamed > 0 || dropped > 0 else { return }
    app.logger.notice(
        "Reconciled legacy migration namespaces \(legacyMigrationPrefixes) -> '\(canonicalMigrationPrefix)': \(renamed) renamed, \(dropped) duplicate(s) removed"
    )
}
