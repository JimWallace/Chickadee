// APIServer/Migrations/ChickadeeMigration.swift
//
// Marker protocol adopted by all of Chickadee's own Fluent migrations so their
// recorded identity is independent of the Swift module they live in.

import Fluent

/// Fluent's default migration `name` is `String(reflecting: Self.self)` — the
/// module-qualified type name (e.g. "APIServer.CreateUsers"). That couples every
/// migration's identity in `_fluent_migrations` to the Swift module, so a
/// target/library rename silently changes every identifier and makes the next
/// boot re-run already-applied migrations (see `reconcileLegacyMigrationNamespace`
/// for the fallout the `chickadee-server` → `APIServer` rename caused).
///
/// Adopting `ChickadeeMigration` pins the identifier to `"chickadee.<TypeName>"`,
/// which does not change when the module is renamed again. Vapor's own
/// migrations (e.g. `SessionRecord`) are not ours and keep their upstream names.
protocol ChickadeeMigration: AsyncMigration {}

extension ChickadeeMigration {
    var name: String { "chickadee." + String(describing: Self.self) }
}
