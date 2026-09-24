// A copied assignment must get its own shared support directory.
//
// Students open an assignment's data files in the editor through
// `shared/<setupID>/`, and personalization expressions import support modules
// from it. Course-bundle import and `clone_assignment` copied the setup zip but
// never extracted it there, so every copied assignment lacked the directory:
// its data files were missing from the editor, and an expression calling a
// support module failed with a `NameError`. These tests cover both copy paths
// and the one-time repair of setups copied before the fix.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

private let supportManifest =
    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}"#

/// Writes a setup zip holding one graded script and one support file.
private func writeSetupZip(at zipPath: String) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("shared-copy-zip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("exit 0\n".utf8).write(to: root.appendingPathComponent("test_a.sh"))
    try Data("pulse,diet\n80,low fat\n".utf8).write(to: root.appendingPathComponent("data.csv"))
    try await writeZipFixture(of: root, to: zipPath)
}

private func sharedDirectory(for setupID: String, on app: Application) -> String {
    app.testSetupsDirectory + "shared/\(setupID)/"
}

@Suite struct SharedSupportFilesCloneTests {
    @Test func aClonedAssignmentGetsItsSupportFiles() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CLONE_SHARED")
            let courseID = try course.requireID()
            let zipPath = app.testSetupsDirectory + "setup_clone_src.zip"
            try await writeSetupZip(at: zipPath)
            let sourceSetup = APITestSetup(
                id: "setup_clone_src", manifest: supportManifest, zipPath: zipPath,
                courseID: courseID)
            try await sourceSetup.save(on: app.db)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "setup_clone_src", courseID: courseID, title: "Lab 8")

            let cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source, sourceSetup: sourceSetup, newTitle: "Lab 8 (W27)",
                targetCourseID: courseID,
                directories: AuthoringDirectories(
                    setups: app.testSetupsDirectory, submissions: app.submissionsDirectory),
                on: app.db)

            let shared = sharedDirectory(for: try cloned.setup.requireID(), on: app)
            #expect(FileManager.default.fileExists(atPath: shared + "data.csv"))
            #expect(!FileManager.default.fileExists(atPath: shared + "test_a.sh"))
        }
    }
}

@Suite(.serialized) final class SharedSupportFilesImportTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-shared-import")
    }

    /// A one-setup bundle whose setup zip carries a support file.
    private func makeBundleZip(courseCode: String) async throws -> Data {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let setupsDir = staging.appendingPathComponent("testsetups", isDirectory: true)
        try FileManager.default.createDirectory(at: setupsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("submissions", isDirectory: true),
            withIntermediateDirectories: true)
        try await writeSetupZip(at: setupsDir.appendingPathComponent("setup_orig.zip").path)

        let manifest = CourseBundleManifest(
            exportedAt: Date(), exportedBy: "test-admin", chickadeeVersion: "0.5.239",
            course: BundledCourse(code: courseCode, name: "Shared Import Course"),
            users: [], enrolledUserBundleIDs: [],
            assignments: [
                BundledAssignment(
                    bundleID: "assign_1", title: "Lab 8", dueAt: nil, isOpen: false,
                    sortOrder: nil, testSetupBundleID: "setup_1")
            ],
            testSetups: [
                BundledTestSetup(
                    bundleID: "setup_1", originalID: "setup_orig", manifest: supportManifest,
                    zipFilename: "testsetups/setup_orig.zip")
            ],
            submissions: [], results: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("bundle.json"))

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-import-out-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        try await createZipArchive(sourceDir: staging, outputPath: outPath)
        return try Data(contentsOf: URL(fileURLWithPath: outPath))
    }

    private func postImport(cookie: String, zipData: Data) async throws -> HTTPStatus {
        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let boundary = "shared-boundary-\(UUID().uuidString)"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
        body.writeString("\(csrf)\r\n--\(boundary)\r\n")
        body.writeString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zipData)
        body.writeString("\r\n--\(boundary)--\r\n")
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = body
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func anImportedAssignmentGetsItsSupportFiles() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "shared_import_admin", password: "testpassword", role: "admin",
                on: app)
            let status = try await postImport(
                cookie: cookie, zipData: try await makeBundleZip(courseCode: "SHARED_IMP"))
            #expect(status != .badRequest && status != .conflict && status != .forbidden)

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "SHARED_IMP").first())
            let setup = try #require(
                try await APITestSetup.query(on: app.db)
                    .filter(\.$courseID == course.requireID()).first())

            let shared = sharedDirectory(for: try setup.requireID(), on: app)
            #expect(FileManager.default.fileExists(atPath: shared + "data.csv"))
            #expect(!FileManager.default.fileExists(atPath: shared + "test_a.sh"))
        }
    }
}

@Suite struct BackfillSharedSupportFilesTests {
    @Test func aSetupWithoutASharedDirectoryIsRepaired() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "BACKFILL_SHARED")
            let zipPath = app.testSetupsDirectory + "setup_copied.zip"
            try await writeSetupZip(at: zipPath)
            try await APITestSetup(
                id: "setup_copied", manifest: supportManifest, zipPath: zipPath,
                courseID: course.requireID()
            ).save(on: app.db)

            try await BackfillSharedSupportFiles(testSetupsDirectory: app.testSetupsDirectory)
                .prepare(on: app.db)

            let shared = sharedDirectory(for: "setup_copied", on: app)
            #expect(FileManager.default.fileExists(atPath: shared + "data.csv"))
        }
    }

    /// A setup that already has a shared directory keeps it exactly as it is.
    @Test func anExistingSharedDirectoryIsLeftAlone() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "BACKFILL_KEEP")
            let zipPath = app.testSetupsDirectory + "setup_kept.zip"
            try await writeSetupZip(at: zipPath)
            try await APITestSetup(
                id: "setup_kept", manifest: supportManifest, zipPath: zipPath,
                courseID: course.requireID()
            ).save(on: app.db)
            let shared = sharedDirectory(for: "setup_kept", on: app)
            try FileManager.default.createDirectory(
                atPath: shared, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: URL(fileURLWithPath: shared + "solution.py"))

            try await BackfillSharedSupportFiles(testSetupsDirectory: app.testSetupsDirectory)
                .prepare(on: app.db)

            #expect(!FileManager.default.fileExists(atPath: shared + "data.csv"))
            #expect(FileManager.default.contents(atPath: shared + "solution.py") == Data("kept".utf8))
        }
    }
}
