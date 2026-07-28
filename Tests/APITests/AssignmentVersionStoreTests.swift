// Tests/APITests/AssignmentVersionStoreTests.swift
//
// The record/dedupe/numbering contract for assignment content snapshots
// (docs/assignment-versioning.md).
//
// These pin the properties the capture points in later slices depend on:
// recording is self-deduping (so a call site may be generous), numbering
// survives concurrent edits, hidden drafts are skipped, and the lazy baseline
// makes the pre-edit state recoverable without a backfill migration.
//
// `.serialized`: each test spawns `zip` / `unzip` subprocesses, which hit the
// Foundation posix_spawn EFAULT race under within-suite parallelism — the same
// reason `ZipArchiverTests` is serialized.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssignmentVersionStoreTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-versions")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let setup: APITestSetup
        let assignment: APIAssignment
        let courseID: UUID
    }

    /// A published assignment whose setup zip holds one test script, plus a
    /// starter notebook on disk.
    private func fixture(
        _ app: Application,
        entries: [(String, String)] = [("publictest_a.py", "passed('ok')\n")],
        notebook: String? = "{\"cells\":[]}",
        publish: Bool = true
    ) async throws -> Fixture {
        let course = APICourse(code: "AV\(Int.random(in: 1000...9999))", name: "Versions", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "av_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: entries)

        var notebookPath: String?
        if let notebook {
            notebookPath = app.testSetupsDirectory + setupID + ".ipynb"
            try Data(notebook.utf8).write(to: URL(fileURLWithPath: notebookPath ?? ""))
        }

        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath,
            notebookPath: notebookPath, courseID: courseID)
        try await setup.save(on: app.db)

        let assignment = APIAssignment(
            testSetupID: setupID, title: "Lab", dueAt: nil, isOpen: true,
            deadlineOverrideActive: false, courseID: courseID)
        if publish { try await assignment.save(on: app.db) }
        return Fixture(setup: setup, assignment: assignment, courseID: courseID)
    }

    /// Packs `entries` into a zip at `zipPath`.
    ///
    /// `modified` stamps every entry's mtime. zip records mtimes at 2-second
    /// granularity, so two packs of identical content inside the same window
    /// come out byte-identical — passing distinct values is how a test makes
    /// "same content, different archive bytes" deterministic instead of
    /// depending on how fast the machine is.
    private func writeZip(
        at zipPath: String, entries: [(String, String)], modified: Date? = nil
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("av-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: target)
            if let modified {
                try FileManager.default.setAttributes(
                    [.modificationDate: modified], ofItemAtPath: target.path)
            }
        }
        try? FileManager.default.removeItem(atPath: zipPath)
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

    private func record(
        _ app: Application, _ setup: APITestSetup, origin: String = "test"
    ) async throws -> AssignmentVersionOutcome {
        try await AssignmentVersionStore.record(
            setup: setup,
            request: AssignmentVersionRequest(origin: origin),
            testSetupsDirectory: app.testSetupsDirectory,
            on: app.db)
    }

    // MARK: - Recording

    @Test func firstRecordCapturesManifestFilesAndNotebook() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)

            let outcome = try await record(app, fx.setup, origin: "mcp:update_suite")
            #expect(outcome == .recorded(version: 1))

            let setupID = try #require(fx.setup.id)
            let version = try #require(
                try await AssignmentVersionStore.newestVersion(setupID: setupID, on: app.db))
            #expect(version.versionNumber == 1)
            #expect(version.origin == "mcp:update_suite")
            #expect(version.manifest == fx.setup.manifest)
            #expect(version.notebookHash != nil)
            #expect(version.decodedFileMap().keys.contains("publictest_a.py"))
            #expect(version.assignmentID == fx.assignment.id)
            #expect(version.courseID == fx.courseID)
        }
    }

    /// Recording twice with nothing changed in between must not write a second
    /// row. This is what lets a capture point be generous about when it calls.
    @Test func recordingUnchangedContentIsANoOp() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)

            #expect(try await record(app, fx.setup) == .recorded(version: 1))
            #expect(try await record(app, fx.setup) == .unchanged(version: 1))

            let count = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == (fx.setup.id ?? ""))
                .count()
            #expect(count == 1)
        }
    }

    /// A repack of byte-identical content produces a different archive (zip
    /// embeds timestamps) — the snapshot must still dedupe, which is exactly
    /// why blobs are per-entry rather than per-archive.
    @Test func repackingIdenticalContentStillDedupes() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            #expect(try await record(app, fx.setup) == .recorded(version: 1))

            let before = try #require(FileManager.default.contents(atPath: fx.setup.zipPath))
            try writeZip(
                at: fx.setup.zipPath, entries: [("publictest_a.py", "passed('ok')\n")],
                modified: Date(timeIntervalSince1970: 1_600_000_000))
            let after = try #require(FileManager.default.contents(atPath: fx.setup.zipPath))
            // Guard the premise: if zip ever became reproducible this test
            // would silently stop testing anything.
            #expect(before != after)

            #expect(try await record(app, fx.setup) == .unchanged(version: 1))
        }
    }

    @Test func changingAScriptRecordsANewVersion() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            #expect(try await record(app, fx.setup) == .recorded(version: 1))

            try writeZip(
                at: fx.setup.zipPath, entries: [("publictest_a.py", "failed('nope')\n")])
            #expect(try await record(app, fx.setup) == .recorded(version: 2))
        }
    }

    @Test func changingTheManifestRecordsANewVersion() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            #expect(try await record(app, fx.setup) == .recorded(version: 1))

            fx.setup.manifest = """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":30,"makefile":null}
                """
            try await fx.setup.save(on: app.db)
            #expect(try await record(app, fx.setup) == .recorded(version: 2))
        }
    }

    @Test func changingTheNotebookRecordsANewVersion() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            #expect(try await record(app, fx.setup) == .recorded(version: 1))

            let path = try #require(fx.setup.notebookPath)
            try Data("{\"cells\":[{\"cell_type\":\"code\"}]}".utf8)
                .write(to: URL(fileURLWithPath: path))
            #expect(try await record(app, fx.setup) == .recorded(version: 2))
        }
    }

    // MARK: - Drafts

    /// Hidden authoring drafts have no published assignment. Their edits aren't
    /// yet anyone's content, so they must not accumulate history.
    @Test func aSetupWithNoPublishedAssignmentIsSkipped() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app, publish: false)

            #expect(try await record(app, fx.setup) == .skipped(reason: .draft))
            let count = try await APIAssignmentVersion.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    // MARK: - Baseline

    /// The pre-edit state has to be captured before the first mutation, or the
    /// very first edit on a pre-existing assignment is the one that can't be
    /// undone.
    @Test func ensureBaselineSeedsVersionOneThenNeverAgain() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)

            let first = try await AssignmentVersionStore.ensureBaseline(
                setup: fx.setup, testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            #expect(first == .recorded(version: 1))

            let setupID = try #require(fx.setup.id)
            let version = try #require(
                try await AssignmentVersionStore.newestVersion(setupID: setupID, on: app.db))
            #expect(version.origin == AssignmentVersionOrigin.baseline)

            // Even after the content moves on, a baseline is never seeded twice.
            try writeZip(at: fx.setup.zipPath, entries: [("publictest_a.py", "changed\n")])
            let second = try await AssignmentVersionStore.ensureBaseline(
                setup: fx.setup, testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            #expect(second == .skipped(reason: .historyExists))
        }
    }

    // MARK: - Numbering

    /// Two concurrent edits on one setup can compute the same next number. The
    /// unique index turns that into an insert conflict and the store retries,
    /// so the history stays gap-free and collision-free.
    @Test func concurrentRecordsProduceDistinctVersionNumbers() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            let setupID = try #require(fx.setup.id)

            // Distinct content per writer, so none of them dedupe away.
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        let setup = APITestSetup(
                            id: setupID, manifest: "{\"schemaVersion\":1,\"n\":\(index)}",
                            zipPath: fx.setup.zipPath, notebookPath: fx.setup.notebookPath,
                            courseID: fx.courseID)
                        _ = try? await AssignmentVersionStore.record(
                            setup: setup,
                            request: AssignmentVersionRequest(origin: "concurrent"),
                            testSetupsDirectory: app.testSetupsDirectory,
                            on: app.db)
                    }
                }
            }

            let numbers = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == setupID)
                .all()
                .map(\.versionNumber)
                .sorted()
            #expect(numbers.count == 4)
            #expect(numbers == Array(1...4))
        }
    }

    // MARK: - Attribution

    @Test func attributionIsDenormalizedOntoTheRow() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            let user = APIUser(username: "ta_kim", passwordHash: "x", role: "user")
            try await user.save(on: app.db)

            _ = try await AssignmentVersionStore.record(
                setup: fx.setup,
                request: AssignmentVersionRequest(
                    origin: AssignmentVersionOrigin.mcp(tool: "author_script"),
                    summary: "added publictest_b.py",
                    actor: user),
                testSetupsDirectory: app.testSetupsDirectory,
                on: app.db)

            let setupID = try #require(fx.setup.id)
            let version = try #require(
                try await AssignmentVersionStore.newestVersion(setupID: setupID, on: app.db))
            #expect(version.actorUserID == user.id)
            #expect(version.actorUsername == "ta_kim")
            #expect(version.origin == "mcp:author_script")
            #expect(version.summary == "added publictest_b.py")
        }
    }

    // MARK: - Degraded inputs

    /// An assignment whose zip is missing on disk is a degraded but real state.
    /// Refusing to snapshot it would mean the one state you most want a record
    /// of is the one that produces none.
    @Test func aMissingZipSnapshotsAsAnEmptyFileMap() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(app)
            try FileManager.default.removeItem(atPath: fx.setup.zipPath)

            #expect(try await record(app, fx.setup) == .recorded(version: 1))
            let setupID = try #require(fx.setup.id)
            let version = try #require(
                try await AssignmentVersionStore.newestVersion(setupID: setupID, on: app.db))
            #expect(version.decodedFileMap().isEmpty)
            #expect(version.manifest == fx.setup.manifest)
        }
    }

    @Test func nestedZipEntriesKeepTheirRelativePaths() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(
                app,
                entries: [
                    ("publictest_a.py", "passed('ok')\n"),
                    ("data/cases.csv", "id\n1\n"),
                ])

            #expect(try await record(app, fx.setup) == .recorded(version: 1))
            let setupID = try #require(fx.setup.id)
            let version = try #require(
                try await AssignmentVersionStore.newestVersion(setupID: setupID, on: app.db))
            let map = version.decodedFileMap()
            #expect(map.keys.contains("data/cases.csv"))
            #expect(map.keys.contains("publictest_a.py"))
        }
    }
}
