// Tests/APITests/CourseBundleImportPathTests.swift
//
// A bundle manifest names its test setup and submission files by path. The
// import accepts only the `<directory>/<name>` form the export writes, so a
// crafted bundle cannot copy a server file into the imported course (#2451).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

private let workerManifestJSON =
    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#

/// A valid empty zip: the 22-byte end-of-central-directory record.
private let emptyZipBytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

@Suite(.serialized, .timeLimit(.minutes(10))) struct CourseBundleImportPathTests {

    private let extractDir = URL(fileURLWithPath: "/bundle/extract")

    @Test func acceptsTheExportedForm() throws {
        let url = try #require(
            bundleEntryURL(extractDir: extractDir, path: "submissions/sub_abc.ipynb", directory: "submissions"))
        #expect(url.path == "/bundle/extract/submissions/sub_abc.ipynb")
    }

    @Test(arguments: [
        "../secret.txt",
        "submissions/../../secret.txt",
        "/etc/passwd",
        "submissions/",
        "submissions/.",
        "submissions/..",
        "submissions/nested/file.zip",
        "testsetups/setup_abc.zip",
        "secret.txt",
        "submissions\\..\\secret.txt",
    ])
    func refusesAnyOtherForm(path: String) {
        #expect(bundleEntryURL(extractDir: extractDir, path: path, directory: "submissions") == nil)
    }

    /// A submission whose path leaves the extract directory is refused, and
    /// the file it names is not copied into the submissions directory.
    @Test func anImportCannotCopyAFileOutsideTheBundle() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("cb-path-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let extractDir = root.appendingPathComponent("extract")
            try fm.createDirectory(
                at: extractDir.appendingPathComponent("testsetups"), withIntermediateDirectories: true)
            try fm.createDirectory(
                at: extractDir.appendingPathComponent("submissions"), withIntermediateDirectories: true)
            try Data(emptyZipBytes).write(to: extractDir.appendingPathComponent("testsetups/setup_cbp.zip"))
            let secret = "not part of the bundle"
            try secret.write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

            let manifest = CourseBundleManifest(
                exportedAt: Date(),
                exportedBy: "test-admin",
                chickadeeVersion: "0.5.0",
                course: BundledCourse(code: "CBPATH1", name: "Bundle Paths"),
                users: [
                    BundledUser(
                        bundleID: "user_1", username: "cbpath_student", displayName: nil, email: nil, role: "user")
                ],
                enrolledUserBundleIDs: ["user_1"],
                assignments: [
                    BundledAssignment(
                        bundleID: "assign_1", title: "Lab 1", dueAt: nil, sortOrder: nil,
                        testSetupBundleID: "setup_1")
                ],
                testSetups: [
                    BundledTestSetup(
                        bundleID: "setup_1", originalID: "setup_cbp", manifest: workerManifestJSON,
                        zipFilename: "testsetups/setup_cbp.zip")
                ],
                submissions: [
                    BundledSubmission(
                        bundleID: "sub_1", userBundleID: "user_1", testSetupBundleID: "setup_1",
                        attemptNumber: 1, submittedAt: nil, filename: "lab.ipynb",
                        submissionFilename: "../secret.txt")
                ],
                results: []
            )
            let submissionsBefore = try fm.contentsOfDirectory(atPath: app.submissionsDirectory)

            await #expect(throws: (any Error).self) {
                _ = try await CourseBundleRoutes().performImportTransaction(
                    app: app,
                    db: app.db,
                    manifest: manifest,
                    dirs: BundleImportDirectories(
                        extractDir: extractDir, setupsDir: app.testSetupsDirectory,
                        subsDir: app.submissionsDirectory, contentFilesDir: app.contentFilesDirectory))
            }

            let submissionsAfter = try fm.contentsOfDirectory(atPath: app.submissionsDirectory)
            #expect(Set(submissionsAfter) == Set(submissionsBefore))
            #expect(try await APICourse.query(on: app.db).filter(\.$code == "CBPATH1").count() == 0)
        }
    }
}
