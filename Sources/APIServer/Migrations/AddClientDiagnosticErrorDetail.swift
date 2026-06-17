// APIServer/Migrations/AddClientDiagnosticErrorDetail.swift
//
// Adds error-detail columns to client_diagnostics so browser-side failures
// carry diagnosable signal, not just a symbolic kind:
//
//   message — the error message (editor_error + kernel-unhealthy watchdog)
//   stack   — the JS stack trace (editor_error)
//   source  — origin of the error: "onerror" | "unhandledrejection" | "kernel"
//
// These capture JupyterLite/Pyodide *infrastructure* errors from the editor
// -load path only — never student-code execution — so no student-authored
// content is stored here.
//
// Shipped as a standalone Add* migration (not folded into
// CreateClientDiagnostics) because production databases have already applied
// CreateClientDiagnostics without these columns and would never pick them up
// from a body change. Fresh deploys run CreateClientDiagnostics then this
// migration; existing prod runs only this one.

import Fluent

struct AddClientDiagnosticErrorDetail: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One column per .update(): SQLite's ALTER TABLE adds a single column
        // per statement, so batching all three into one update produces invalid
        // SQL there (Postgres would accept it).
        try await database.schema("client_diagnostics").field("message", .string).update()
        try await database.schema("client_diagnostics").field("stack", .string).update()
        try await database.schema("client_diagnostics").field("source", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("client_diagnostics").deleteField("message").update()
        try await database.schema("client_diagnostics").deleteField("stack").update()
        try await database.schema("client_diagnostics").deleteField("source").update()
    }
}
