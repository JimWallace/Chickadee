// APIServer/Migrations/CreateValidationVariants.swift
//
// The per-variant validation records (see `ValidationVariant`): one row per
// synthetic seed the current validation batch graded the reference solution
// against.  `submission_id` is `.setNull` on delete so retention pruning an
// old validation submission leaves the recorded verdict standing.

import Fluent

struct CreateValidationVariants: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("validation_variants")
            .id()
            .field("test_setup_id", .string, .required)
            .field("variant_index", .int, .required)
            .field("seed_hex", .string, .required)
            .field(
                "submission_id", .string,
                .references("submissions", "id", onDelete: .setNull)
            )
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("validation_variants").delete()
    }
}
