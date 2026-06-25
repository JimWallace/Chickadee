// APIServer/Migrations/AddClientDiagnosticAppVersion.swift
//
// Adds the `app_version` column to client_diagnostics: the ChickadeeVersion of
// the page build that emitted each browser diagnostic (from the `app-version`
// meta tag). It lets a report be attributed to a build — an OLD value flags a
// stale browser tab still running pre-deploy code (and serving its cached
// editor bundle/wheel), so a recurring failure on an old appVersion reads as a
// stale-cache symptom rather than a live regression.
//
// Shipped as a standalone Add* migration (not folded into
// CreateClientDiagnostics) because production databases have already applied
// CreateClientDiagnostics without this column and would never pick it up from a
// model change. Fresh deploys run CreateClientDiagnostics then this migration;
// existing prod runs only this one. Nullable, so existing rows and older clients
// that don't send the field stay valid.

import Fluent

struct AddClientDiagnosticAppVersion: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("client_diagnostics").field("app_version", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("client_diagnostics").deleteField("app_version").update()
    }
}
