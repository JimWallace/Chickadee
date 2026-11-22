// Tests/APITests/Courses/CourseBundleRouteFixtures.swift
//
// The fixtures that the course bundle route suites share: the export, import
// validation, import records and round-trip suites. Each suite is a class with
// a stored `app`, and conforming to `CourseBundleRouteFixtures` gives it these
// helpers.

import Core
import Fluent
import Foundation
import VaporTesting

@testable import APIServer

/// A course bundle route suite: a class suite with a stored test `app`.
protocol CourseBundleRouteFixtures: AnyObject {
    var app: Application { get }
}

extension CourseBundleRouteFixtures {

    // MARK: - Fixture helpers

    @discardableResult
    func makeTestCourse(code: String) async throws -> APICourse {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == code).first() {
            return existing
        }
        let course = APICourse(code: code, name: "Bundle Test Course")
        try await course.save(on: app.db)
        return course
    }

    @discardableResult
    func insertSetupWithZip(id: String, courseID: UUID) async throws -> APITestSetup {
        let manifest = """
            {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        // Minimal valid ZIP end-of-central-directory record (22 bytes)
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            .write(to: URL(fileURLWithPath: zipPath))
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    func insertAssignment(
        testSetupID: String, title: String = "Test Lab",
        courseID: UUID
    ) async throws -> APIAssignment {
        let a = APIAssignment(
            testSetupID: testSetupID, title: title,
            dueAt: nil, visibility: .open, courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    // MARK: - Bundle construction helpers

    static var dummyZipBytes: [UInt8] {
        [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
    }

    static var workerManifestJSON: String {
        TestManifests.workerEmptyExplicit
    }

    /// Builds a minimal valid bundle ZIP: one test setup, one assignment, no submissions/results.
    func makeMinimalBundleZip(
        courseCode: String, sections: [BundledSection] = [], contentItems: [BundledContentItem] = []
    ) async throws -> Data {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let setupsDir = stagingDir.appendingPathComponent("testsetups", isDirectory: true)
        try FileManager.default.createDirectory(at: setupsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagingDir.appendingPathComponent("submissions", isDirectory: true),
            withIntermediateDirectories: true)

        let setupOrigID = "setup_mintest"
        let manifest = CourseBundleManifest(
            exportedAt: Date(),
            exportedBy: "test-admin",
            chickadeeVersion: "0.2.0",
            course: BundledCourse(code: courseCode, name: "Minimal Import Course"),
            users: [],
            enrolledUserBundleIDs: [],
            sections: sections,
            contentItems: contentItems,
            assignments: [
                BundledAssignment(
                    bundleID: "assign_1", title: "Lab 1",
                    dueAt: nil, isOpen: false, sortOrder: nil,
                    testSetupBundleID: "setup_1")
            ],
            testSetups: [
                BundledTestSetup(
                    bundleID: "setup_1", originalID: setupOrigID,
                    manifest: Self.workerManifestJSON,
                    zipFilename: "testsetups/\(setupOrigID).zip")
            ],
            submissions: [],
            results: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingDir.appendingPathComponent("bundle.json"))
        try Data(Self.dummyZipBytes).write(to: setupsDir.appendingPathComponent("\(setupOrigID).zip"))

        return try await zipDir(stagingDir)
    }

    /// Zips a staging directory and returns the bytes.
    func zipDir(_ dir: URL) async throws -> Data {
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-out-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        try await createZipArchive(sourceDir: dir, outputPath: outPath)
        return try Data(contentsOf: URL(fileURLWithPath: outPath))
    }

    /// Posts a bundle ZIP to /admin/courses/import, including a valid CSRF token.
    func postImport(
        cookie: String, zipData: Data
    ) async throws
        -> (status: HTTPStatus, body: String)
    {
        // Fetch a CSRF token bound to this session before submitting the form.
        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let res = try await postMultipartForm(
            "/admin/courses/import", cookie: sessionCookie, fields: [("_csrf", csrf)],
            files: [("file", "bundle.zip", "application/zip", zipData)], on: app)
        return (res.status, res.body.string)
    }

    // MARK: - Bundle builder with a user (used by user-matching tests)

    func makeBundleZipWithUser(courseCode: String, username: String) async throws -> Data {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-user-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let setupsDir = stagingDir.appendingPathComponent("testsetups", isDirectory: true)
        try FileManager.default.createDirectory(at: setupsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagingDir.appendingPathComponent("submissions", isDirectory: true),
            withIntermediateDirectories: true)

        let setupOrigID = "setup_usrtest"
        let manifest = CourseBundleManifest(
            exportedAt: Date(),
            exportedBy: "test-admin",
            chickadeeVersion: "0.2.0",
            course: BundledCourse(code: courseCode, name: "User Test Course"),
            users: [
                BundledUser(
                    bundleID: "user_1", username: username,
                    displayName: nil, email: nil, role: "student")
            ],
            enrolledUserBundleIDs: ["user_1"],
            assignments: [],
            testSetups: [
                BundledTestSetup(
                    bundleID: "setup_1", originalID: setupOrigID,
                    manifest: Self.workerManifestJSON,
                    zipFilename: "testsetups/\(setupOrigID).zip")
            ],
            submissions: [],
            results: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: stagingDir.appendingPathComponent("bundle.json"))
        try Data(Self.dummyZipBytes).write(to: setupsDir.appendingPathComponent("\(setupOrigID).zip"))

        return try await zipDir(stagingDir)
    }
}
