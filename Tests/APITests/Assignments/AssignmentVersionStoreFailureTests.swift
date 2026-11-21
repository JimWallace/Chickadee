// Tests/APITests/Assignments/AssignmentVersionStoreFailureTests.swift
//
// The failure paths of `AssignmentVersionStore` (docs/assignment-versioning.md)
// that `AssignmentVersionStoreTests` and `AssignmentVersionLifecycleTests` do
// not reach:
//
//   - The best-effort wrappers (`recordBestEffort`, `seedInitialVersion`)
//     return nil and write no row when a snapshot fails, so the edit itself
//     still succeeds.
//   - A row that the database refuses on every numbering attempt surfaces the
//     database error, and burns no version number.
//   - `reclaimOrphanedBlobs` reports what it reclaimed, and skips collection
//     when it cannot read the reference set (fail closed).
//
// `.serialized`: the suite touches the database and spawns zip subprocesses.

import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) final class AssignmentVersionStoreFailureTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vfail")
    }

    /// A published assignment whose setup zip holds one test script.
    private func publishedSetup(_ app: Application, setupID: String) async throws -> APITestSetup {
        let scenario = try await TestScenario.make(
            on: app, code: "VF\(Int.random(in: 1000...9999))", setupID: setupID, withNotebook: false)
        try await writeZipFixture(at: scenario.setup.zipPath, entries: [("test_a.sh", "exit 0\n")])
        return scenario.setup
    }

    private func versionCount(_ app: Application, setupID: String) async throws -> Int {
        try await APIAssignmentVersion.query(on: app.db).filter(\.$testSetupID == setupID).count()
    }

    /// Writes bytes that are not a zip over the setup's archive, so the
    /// snapshot builder throws.
    private func corruptZip(of setup: APITestSetup) throws {
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: setup.zipPath))
    }

    // MARK: - Best-effort wrappers

    @Test func recordBestEffortReturnsNilAndWritesNoRowWhenTheSnapshotFails() async throws {
        try await withApp(app) { app in
            let setup = try await publishedSetup(app, setupID: "vf_best")
            try corruptZip(of: setup)

            let outcome = await AssignmentVersionStore.recordBestEffort(
                setup: setup,
                request: AssignmentVersionRequest(origin: AssignmentVersionOrigin.web(action: "save_edit")),
                testSetupsDirectory: app.testSetupsDirectory,
                logger: app.logger,
                on: app.db)

            #expect(outcome == nil)
            #expect(try await versionCount(app, setupID: "vf_best") == 0)
        }
    }

    @Test func seedInitialVersionReturnsNilWhenTheSnapshotFails() async throws {
        try await withApp(app) { app in
            let setup = try await publishedSetup(app, setupID: "vf_seed")
            try corruptZip(of: setup)

            let outcome = await AssignmentVersionStore.seedInitialVersion(
                setup: setup, origin: AssignmentVersionOrigin.create,
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)

            #expect(outcome == nil)
            #expect(try await versionCount(app, setupID: "vf_seed") == 0)
        }
    }

    /// The same wrapper passes a successful outcome through unchanged.
    @Test func seedInitialVersionRecordsVersionOneWithItsOrigin() async throws {
        try await withApp(app) { app in
            let setup = try await publishedSetup(app, setupID: "vf_seed_ok")

            let outcome = await AssignmentVersionStore.seedInitialVersion(
                setup: setup, origin: AssignmentVersionOrigin.clone,
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)

            #expect(outcome == .recorded(version: 1))
            let newest = try #require(
                try await AssignmentVersionStore.newestVersion(setupID: "vf_seed_ok", on: app.db))
            #expect(newest.origin == "clone")
        }
    }

    // MARK: - Numbering

    /// An actor that is not a saved account violates the `actor_user_id`
    /// foreign key on every attempt. The store gives up after its retries and
    /// throws the database error; it does not report a version it never wrote.
    @Test func aRowTheDatabaseRefusesThrowsAndBurnsNoNumber() async throws {
        try await withApp(app) { app in
            let setup = try await publishedSetup(app, setupID: "vf_fk")
            let ghost = APIUser(id: UUID(), username: "ghost", passwordHash: "x", role: "user")

            await #expect(throws: (any Error).self) {
                try await AssignmentVersionStore.record(
                    setup: setup,
                    request: AssignmentVersionRequest(origin: "web:edit", actor: ghost),
                    testSetupsDirectory: app.testSetupsDirectory,
                    on: app.db)
            }
            #expect(try await versionCount(app, setupID: "vf_fk") == 0)

            // The next valid snapshot is still version 1.
            let outcome = try await AssignmentVersionStore.record(
                setup: setup,
                request: AssignmentVersionRequest(origin: "web:edit"),
                testSetupsDirectory: app.testSetupsDirectory,
                on: app.db)
            #expect(outcome == .recorded(version: 1))
        }
    }

    // MARK: - Reclamation

    /// An orphan outside the grace window is deleted and counted; a blob that a
    /// version row references stays.
    @Test func reclaimDeletesAnOldOrphanAndReportsIt() async throws {
        try await withApp(app) { app in
            let setup = try await publishedSetup(app, setupID: "vf_reclaim")
            try await AssignmentVersionStore.record(
                setup: setup,
                request: AssignmentVersionRequest(origin: "web:edit"),
                testSetupsDirectory: app.testSetupsDirectory,
                on: app.db)
            let referenced = try await AssignmentVersionStore.referencedBlobHashes(on: app.db)
            #expect(!referenced.isEmpty)

            let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
            let orphanBytes = Data("no version references this blob\n".utf8)
            let orphan = try blobs.put(orphanBytes)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: blobs.path(for: orphan))

            let result = try #require(
                await AssignmentVersionStore.reclaimOrphanedBlobs(
                    testSetupsDirectory: app.testSetupsDirectory, logger: app.logger, on: app.db))

            #expect(result.blobsDeleted == 1)
            #expect(result.bytesFreed == orphanBytes.count)
            #expect(!blobs.exists(orphan))
            for hash in referenced { #expect(blobs.exists(hash)) }
        }
    }

    /// When the reference set cannot be read, nothing is deleted: a partial
    /// set would mark live blobs as garbage. An aborted transaction makes
    /// every query on its connection fail.
    @Test func reclaimSkipsCollectionWhenTheReferenceSetCannotBeRead() async throws {
        struct RollBack: Error {
            let result: AssignmentVersionBlobStore.GarbageCollectionResult?
        }
        try await withApp(app) { app in
            let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
            let orphan = try blobs.put(Data("old orphan\n".utf8))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: blobs.path(for: orphan))
            let directory = app.testSetupsDirectory
            let logger = app.logger

            var rolledBack: RollBack?
            do {
                try await app.db.transaction { db in
                    let sql = try #require(db as? any SQLDatabase)
                    _ = try? await sql.raw("SELECT 1 / 0").run()
                    throw RollBack(
                        result: await AssignmentVersionStore.reclaimOrphanedBlobs(
                            testSetupsDirectory: directory, logger: logger, on: db))
                }
            } catch let error as RollBack {
                rolledBack = error
            }

            let reached = try #require(rolledBack)
            #expect(reached.result == nil)
            #expect(blobs.exists(orphan))
        }
    }
}
