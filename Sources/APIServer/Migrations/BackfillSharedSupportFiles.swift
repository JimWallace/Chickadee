// APIServer/Migrations/BackfillSharedSupportFiles.swift
//
// One-time repair for test setups that were copied without their shared
// support directory.

import Fluent
import Foundation

/// Extracts the support files of every test setup that has no shared directory.
///
/// Course-bundle import and `clone_assignment` copied the setup zip but never
/// ran `extractSupportFilesToSharedDirectory`, so every copied assignment
/// lacked `shared/<setupID>/`. Its students could not open its data files in
/// the editor, and a personalization expression that calls a support module
/// (`dbgen.generate_patients(seed)`) failed with a `NameError`, so the tests
/// that read those inputs failed for everyone. Both copy paths now extract;
/// this repairs the setups they copied before that.
///
/// A setup that already has a shared directory is skipped, so an author's
/// later edits are never overwritten. A setup with no support files gets no
/// directory from the extraction, which is correct: there is nothing to share.
struct BackfillSharedSupportFiles: ChickadeeMigration {
    let testSetupsDirectory: String

    func prepare(on database: Database) async throws {
        // A full model query is safe here because this migration is registered
        // after every migration that adds a column to `test_setups` (#1077).
        let setups = try await APITestSetup.query(on: database).all()
        let fm = FileManager.default
        var repaired = 0

        for setup in setups {
            guard let setupID = setup.id,
                fm.fileExists(atPath: setup.zipPath),
                !fm.fileExists(atPath: testSetupsDirectory + "shared/\(setupID)/")
            else { continue }
            await extractSupportFilesToSharedDirectory(
                for: setup, testSetupsDirectory: testSetupsDirectory)
            if fm.fileExists(atPath: testSetupsDirectory + "shared/\(setupID)/") {
                repaired += 1
            }
        }

        database.logger.info(
            "backfill_shared_support_files: \(repaired) test setup(s) given a shared directory")
    }

    /// A no-op: the extracted files are a copy of what the zip already holds,
    /// and removing them would break the students who now link to them.
    func revert(on database: Database) async throws {}
}
