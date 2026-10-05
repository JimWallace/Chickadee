// Tests/APITests/CourseBundleImportCleanupTests.swift
//
// A bundle import that fails part-way leaves no files behind (#2164). The
// rows roll back with the transaction; the import removes the files it
// wrote, as the course clone does (#1743).

import Core
import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

private let workerManifestJSON =
    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#

/// A valid empty zip: the 22-byte end-of-central-directory record.
private let emptyZipBytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

private let emptyNotebookJSON = #"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#

@Suite(.serialized, .timeLimit(.minutes(10))) struct CourseBundleImportCleanupTests {

    /// Everything under `directory` except the version blob store, which the
    /// grace-window reaper owns (#1743).
    private func listing(of directory: String) throws -> Set<String> {
        Set(
            try FileManager.default.subpathsOfDirectory(atPath: directory)
                .filter { $0 != "versions" && !$0.hasPrefix("versions/") })
    }

    /// An extracted bundle on disk: one setup zip and one submission file,
    /// laid out as the manifest names them.
    private func writeExtractedBundle() throws -> URL {
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-cleanup-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: extractDir.appendingPathComponent("testsetups"), withIntermediateDirectories: true)
        try fm.createDirectory(at: extractDir.appendingPathComponent("submissions"), withIntermediateDirectories: true)
        try Data(emptyZipBytes).write(to: extractDir.appendingPathComponent("testsetups/setup_climp.zip"))
        try emptyNotebookJSON.write(
            to: extractDir.appendingPathComponent("submissions/sub_climp.ipynb"), atomically: true, encoding: .utf8)
        return extractDir
    }

    private func manifest() -> CourseBundleManifest {
        CourseBundleManifest(
            exportedAt: Date(),
            exportedBy: "test-admin",
            chickadeeVersion: "0.5.0",
            course: BundledCourse(code: "CLIMP1", name: "Import Cleanup"),
            users: [
                BundledUser(bundleID: "user_1", username: "climp_student", displayName: nil, email: nil, role: "user")
            ],
            enrolledUserBundleIDs: ["user_1"],
            assignments: [
                BundledAssignment(
                    bundleID: "assign_1", title: "Lab 1", dueAt: nil, sortOrder: nil, testSetupBundleID: "setup_1")
            ],
            testSetups: [
                BundledTestSetup(
                    bundleID: "setup_1", originalID: "setup_climp", manifest: workerManifestJSON,
                    zipFilename: "testsetups/setup_climp.zip")
            ],
            submissions: [
                BundledSubmission(
                    bundleID: "sub_1", userBundleID: "user_1", testSetupBundleID: "setup_1",
                    attemptNumber: 1, submittedAt: nil, filename: "lab.ipynb",
                    submissionFilename: "submissions/sub_climp.ipynb")
            ],
            results: [
                BundledResult(
                    submissionBundleID: "sub_1", collectionJSON: #"{"submissionID":"sub_1","outcomes":[]}"#,
                    source: "worker", receivedAt: nil)
            ]
        )
    }

    /// The result insert fails last, after the setup zip, the shared
    /// directory and the submission file were written. Afterwards the setups
    /// and submissions directories hold what they held before, and no course
    /// row exists.
    @Test func aFailedImportLeavesNoFiles() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let extractDir = try writeExtractedBundle()
            defer { try? FileManager.default.removeItem(at: extractDir) }
            try FileManager.default.createDirectory(
                atPath: app.testSetupsDirectory + "shared/", withIntermediateDirectories: true)
            let setupsBefore = try listing(of: app.testSetupsDirectory)
            let submissionsBefore = try listing(of: app.submissionsDirectory)

            await #expect(throws: (any Error).self) {
                _ = try await CourseBundleRoutes().performImportTransaction(
                    app: app,
                    db: FailingInsertDatabase(base: app.db, schema: APIResult.schema),
                    manifest: manifest(),
                    dirs: BundleImportDirectories(
                        extractDir: extractDir, setupsDir: app.testSetupsDirectory,
                        subsDir: app.submissionsDirectory, contentFilesDir: app.contentFilesDirectory))
            }

            #expect(try listing(of: app.testSetupsDirectory) == setupsBefore)
            #expect(try listing(of: app.submissionsDirectory) == submissionsBefore)
            #expect(try await APICourse.query(on: app.db).filter(\.$code == "CLIMP1").count() == 0)
        }
    }
}

/// Forwards every query to `base` and fails the first insert into `schema`.
/// A transaction opened through it hands the closure a wrapped connection,
/// so the refusal reaches a nested transaction too.
private struct FailingInsertDatabase: Database {
    struct InsertRefused: Error {}

    let base: any Database
    let schema: String

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        if query.schema == schema, case .create = query.action {
            return base.eventLoop.makeFailedFuture(InsertRefused())
        }
        return base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { base.execute(schema: schema) }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { base.execute(enum: `enum`) }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let schema = self.schema
        return base.transaction { inner in closure(FailingInsertDatabase(base: inner, schema: schema)) }
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let schema = self.schema
        return base.withConnection { inner in closure(FailingInsertDatabase(base: inner, schema: schema)) }
    }
}
