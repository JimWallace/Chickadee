// Tests/APITests/AssignmentVersionLifecycleTests.swift
//
// Creation-path seeding and blob reclamation for assignment content versioning
// (docs/assignment-versioning.md).
//
// Two properties the feature's storage story rests on:
//
//   - A cloned or freshly created assignment starts with its own v1, and
//     inherits NO history from its source — "only the most recent version
//     travels" when a course is copied for a new term.
//   - Blobs are reclaimed only when the version rows referencing them are gone,
//     and never while a concurrent snapshot might be mid-write.
//
// `.serialized`: these spawn zip subprocesses.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) final class AssignmentVersionLifecycleTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vlife")
    }

    // MARK: - Fixtures

    private func makeCourse(_ app: Application, code: String) async throws -> UUID {
        let course = APICourse(code: code, name: "Lifecycle \(code)", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return try course.requireID()
    }

    private func makeAssignment(
        _ app: Application, courseID: UUID, scripts: [(String, String)] = [("test_a.sh", "exit 0\n")],
        title: String = "Source lab"
    ) async throws -> (assignment: APIAssignment, setup: APITestSetup) {
        let setupID = "vl_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: [(".placeholder", "x")] + scripts)
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: title, dueAt: nil, isOpen: false,
            deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)
        return (assignment, setup)
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vl-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
    }

    private func versions(
        _ app: Application, _ setupID: String
    ) async throws
        -> [APIAssignmentVersion]
    {
        try await APIAssignmentVersion.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .sort(\.$versionNumber)
            .all()
    }

    // MARK: - Creation seeding

    /// A clone starts with its own v1 stamped `clone`, and — because the copy
    /// lands in a new setup id — inherits none of the source's history. That is
    /// the "only the most recent version travels" rule for a new term.
    @Test func cloningSeedsAFreshV1AndInheritsNoHistory() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "VLSRC")
            let (assignment, setup) = try await makeAssignment(app, courseID: courseID)

            // Give the SOURCE a history worth not inheriting.
            for step in 1...3 {
                setup.manifest = "{\"schemaVersion\":1,\"n\":\(step)}"
                try await setup.save(on: app.db)
                _ = try await AssignmentVersionStore.record(
                    setup: setup,
                    request: AssignmentVersionRequest(origin: "web:edit"),
                    testSetupsDirectory: app.testSetupsDirectory,
                    on: app.db)
            }
            #expect(try await versions(app, setup.id ?? "").count == 3)

            let cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: assignment, sourceSetup: setup, newTitle: "Cloned lab",
                targetCourseID: courseID, setupsDirectory: app.testSetupsDirectory, on: app.db)

            let clonedHistory = try await versions(app, cloned.setup.id ?? "")
            #expect(clonedHistory.count == 1)
            #expect(clonedHistory.first?.versionNumber == 1)
            #expect(clonedHistory.first?.origin == AssignmentVersionOrigin.clone)
            // The clone's v1 holds the source's CURRENT content, not its first.
            #expect(clonedHistory.first?.manifest == setup.manifest)
            // The source's own history is untouched.
            #expect(try await versions(app, setup.id ?? "").count == 3)
        }
    }

    @Test func creatingFromScratchSeedsAV1() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "VLNEW")
            let created = try await AssignmentAuthoringService.createAssignment(
                courseID: courseID, title: "From scratch",
                notebookData: Data("{\"cells\":[],\"nbformat\":4}".utf8),
                setupsDirectory: app.testSetupsDirectory, on: app.db)

            let history = try await versions(app, created.setup.id ?? "")
            #expect(history.count == 1)
            #expect(history.first?.origin == AssignmentVersionOrigin.create)
            #expect(history.first?.notebookHash != nil)
        }
    }

    // MARK: - Reclamation

    /// The safety property: a blob a surviving version references is never
    /// collected, however old it is.
    @Test func referencedBlobsSurviveCollection() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "VLKEEP")
            let (_, setup) = try await makeAssignment(app, courseID: courseID)
            _ = try await AssignmentVersionStore.record(
                setup: setup,
                request: AssignmentVersionRequest(origin: "web:edit"),
                testSetupsDirectory: app.testSetupsDirectory,
                on: app.db)

            let referenced = try await AssignmentVersionStore.referencedBlobHashes(on: app.db)
            #expect(!referenced.isEmpty)

            let blobs = AssignmentVersionBlobStore(
                testSetupsDirectory: app.testSetupsDirectory)
            // now far in the future so the grace window can't be what saves them.
            let result = blobs.collectGarbage(
                referenced: referenced, graceSeconds: 3600,
                now: Date().addingTimeInterval(86_400))

            #expect(result.blobsDeleted == 0)
            for hash in referenced { #expect(blobs.exists(hash)) }
        }
    }

    /// An unreferenced blob is reclaimed once it is outside the grace window.
    @Test func unreferencedBlobsAreCollectedAfterTheGraceWindow() async throws {
        try await withApp(app) { app in
            let blobs = AssignmentVersionBlobStore(
                testSetupsDirectory: app.testSetupsDirectory)
            let orphan = try blobs.put(Data("nothing references me\n".utf8))
            #expect(blobs.exists(orphan))

            let result = blobs.collectGarbage(
                referenced: [], graceSeconds: 3600, now: Date().addingTimeInterval(86_400))

            #expect(result.blobsDeleted == 1)
            #expect(result.bytesFreed > 0)
            #expect(!blobs.exists(orphan))
        }
    }

    /// The write race: a snapshot stores blobs BEFORE the row that references
    /// them. A collection running in that window must not delete the bytes the
    /// about-to-commit row points at.
    @Test func freshBlobsAreProtectedByTheGraceWindow() async throws {
        try await withApp(app) { app in
            let blobs = AssignmentVersionBlobStore(
                testSetupsDirectory: app.testSetupsDirectory)
            let inFlight = try blobs.put(Data("row not committed yet\n".utf8))

            let result = blobs.collectGarbage(referenced: [], graceSeconds: 3600)

            #expect(result.blobsDeleted == 0)
            #expect(blobs.exists(inFlight))
        }
    }

    /// Deleting a course takes its version rows (FK cascade), which is what
    /// makes its blobs collectable — and another course's blobs must survive it.
    @Test func deletingACourseFreesOnlyItsOwnBlobs() async throws {
        try await withApp(app) { app in
            let doomedID = try await makeCourse(app, code: "VLGONE")
            let keptID = try await makeCourse(app, code: "VLSTAY")
            let (_, doomedSetup) = try await makeAssignment(
                app, courseID: doomedID, scripts: [("only_in_doomed.sh", "exit 7\n")])
            let (_, keptSetup) = try await makeAssignment(
                app, courseID: keptID, scripts: [("only_in_kept.sh", "exit 9\n")])

            for setup in [doomedSetup, keptSetup] {
                _ = try await AssignmentVersionStore.record(
                    setup: setup,
                    request: AssignmentVersionRequest(origin: "web:edit"),
                    testSetupsDirectory: app.testSetupsDirectory,
                    on: app.db)
            }

            let doomedHashes = Set(
                try await versions(app, doomedSetup.id ?? "").flatMap {
                    $0.decodedFileMap().values
                })
            let keptHashes = Set(
                try await versions(app, keptSetup.id ?? "").flatMap { $0.decodedFileMap().values })
            let uniqueToDoomed = doomedHashes.subtracting(keptHashes)
            #expect(!uniqueToDoomed.isEmpty)

            // Cascade the doomed course's version rows away.
            try await APICourse.query(on: app.db).filter(\.$id == doomedID).delete()
            #expect(try await versions(app, doomedSetup.id ?? "").isEmpty)

            let blobs = AssignmentVersionBlobStore(
                testSetupsDirectory: app.testSetupsDirectory)
            let referenced = try await AssignmentVersionStore.referencedBlobHashes(on: app.db)
            _ = blobs.collectGarbage(
                referenced: referenced, graceSeconds: 0, now: Date().addingTimeInterval(86_400))

            for hash in uniqueToDoomed { #expect(!blobs.exists(hash)) }
            for hash in keptHashes { #expect(blobs.exists(hash)) }
        }
    }

    /// Reclamation must fail closed. `reclaimOrphanedBlobs` builds its
    /// reference set from a complete scan; the shared-blob case proves it does
    /// not treat "referenced by a different setup" as garbage.
    @Test func reclaimKeepsBlobsSharedAcrossSetups() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "VLSHARE")
            // Identical script content in two setups → one shared blob.
            let (_, first) = try await makeAssignment(
                app, courseID: courseID, scripts: [("shared.sh", "exit 0\n")], title: "First lab")
            let (_, second) = try await makeAssignment(
                app, courseID: courseID, scripts: [("shared.sh", "exit 0\n")], title: "Second lab")
            for setup in [first, second] {
                _ = try await AssignmentVersionStore.record(
                    setup: setup,
                    request: AssignmentVersionRequest(origin: "web:edit"),
                    testSetupsDirectory: app.testSetupsDirectory,
                    on: app.db)
            }

            let sharedHash = try #require(
                try await versions(app, first.id ?? "").first?.decodedFileMap()["shared.sh"])
            #expect(
                try await versions(app, second.id ?? "").first?.decodedFileMap()["shared.sh"]
                    == sharedHash)

            // Drop only the first setup's history.
            try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == (first.id ?? ""))
                .delete()

            _ = await AssignmentVersionStore.reclaimOrphanedBlobs(
                testSetupsDirectory: app.testSetupsDirectory, logger: app.logger, on: app.db)

            let blobs = AssignmentVersionBlobStore(
                testSetupsDirectory: app.testSetupsDirectory)
            #expect(blobs.exists(sharedHash))
        }
    }
}
