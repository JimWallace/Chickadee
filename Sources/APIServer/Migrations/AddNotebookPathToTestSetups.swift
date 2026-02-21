// APIServer/Migrations/AddNotebookPathToTestSetups.swift
//
// Phase 8: adds a nullable notebook_path column to test_setups.
// Browser-mode setups store the flat .ipynb file path here so instructors
// can edit and re-save notebooks without re-uploading the zip.

import Fluent

struct AddNotebookPathToTestSetups: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_setups")
            .field("notebook_path", .string)    // nullable — nil for worker-mode setups
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_setups")
            .deleteField("notebook_path")
            .update()
    }
}
