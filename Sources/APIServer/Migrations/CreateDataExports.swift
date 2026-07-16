// APIServer/Migrations/CreateDataExports.swift
//
// Personal-data export tracking (#557 — FIPPA / PIPEDA subject access).
// One row per user (unique on user_id): the row is reset in place on a
// re-request, so it doubles as the one-export-per-day rate-limit ledger.
// Cascade-deletes follow the parent user.

import Fluent

struct CreateDataExports: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("data_exports")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("status", .string, .required)
            .field("requested_at", .datetime, .required)
            .field("completed_at", .datetime)
            .field("zip_path", .string)
            .field("file_size_bytes", .int)
            .field("failure_reason", .string)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("data_exports").delete()
    }
}
