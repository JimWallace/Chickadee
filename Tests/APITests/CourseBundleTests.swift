// Tests/APITests/CourseBundleTests.swift
//
// Integration tests for course bundle export and import.
//
//   GET  /admin/courses/:courseID/export  — stream a bundle ZIP (admin only)
//   POST /admin/courses/import            — accept an uploaded bundle ZIP (admin only)
//
// Closes #69 and #70.

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation
import Core

final class CourseBundleTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cbtest-\(UUID().uuidString)/")
            .path

        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = dirs[0]
        app.testSetupsDirectory  = dirs[1]
        app.submissionsDirectory = dirs[2]

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateCourses())
        app.migrations.add(CreateCourseEnrollments())
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(CreateAssignments())
        app.migrations.add(CreatePerformanceIndexes())
        try await app.autoMigrate().get()

        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Auth helpers

    private func loginAsAdmin() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "testadmin_cb", passwordHash: hash, role: "admin")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "testadmin_cb", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    private func loginAsStudent() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "teststudent_cb", passwordHash: hash, role: "student")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "teststudent_cb", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func makeTestCourse(code: String) async throws -> APICourse {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == code).first() {
            return existing
        }
        let course = APICourse(code: code, name: "Bundle Test Course")
        try await course.save(on: app.db)
        return course
    }

    @discardableResult
    private func insertSetupWithZip(id: String, courseID: UUID) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """
        let zipPath = tmpDir + "testsetups/\(id).zip"
        // Minimal valid ZIP end-of-central-directory record (22 bytes)
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            .write(to: URL(fileURLWithPath: zipPath))
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String = "Test Lab",
                                  courseID: UUID) async throws -> APIAssignment {
        let a = APIAssignment(testSetupID: testSetupID, title: title,
                              dueAt: nil, isOpen: true, courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    // MARK: - Bundle construction helpers

    private static let dummyZipBytes: [UInt8] =
        [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

    private static let workerManifestJSON =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#

    /// Builds a minimal valid bundle ZIP: one test setup, one assignment, no submissions/results.
    private func makeMinimalBundleZip(courseCode: String) async throws -> Data {
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
            exportedAt:            Date(),
            exportedBy:            "test-admin",
            chickadeeVersion:      "0.2.0",
            course:                BundledCourse(code: courseCode, name: "Minimal Import Course"),
            users:                 [],
            enrolledUserBundleIDs: [],
            assignments: [
                BundledAssignment(bundleID: "assign_1", title: "Lab 1",
                                  dueAt: nil, isOpen: false, sortOrder: nil,
                                  testSetupBundleID: "setup_1")
            ],
            testSetups: [
                BundledTestSetup(bundleID: "setup_1", originalID: setupOrigID,
                                 manifest: Self.workerManifestJSON,
                                 zipFilename: "testsetups/\(setupOrigID).zip")
            ],
            submissions: [],
            results:     []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingDir.appendingPathComponent("bundle.json"))
        try Data(Self.dummyZipBytes).write(to: setupsDir.appendingPathComponent("\(setupOrigID).zip"))

        return try await zipDir(stagingDir)
    }

    /// Zips a staging directory and returns the bytes.
    private func zipDir(_ dir: URL) async throws -> Data {
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-out-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        try await createZipArchive(sourceDir: dir, outputPath: outPath)
        return try Data(contentsOf: URL(fileURLWithPath: outPath))
    }

    /// Constructs a multipart/form-data body with a single "file" field.
    private func makeMultipartBody(fileData: Data, boundary: String) -> ByteBuffer {
        var buf = ByteBuffer()
        buf.writeString("--\(boundary)\r\n")
        buf.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        buf.writeString("Content-Type: application/zip\r\n\r\n")
        buf.writeBytes(fileData)
        buf.writeString("\r\n--\(boundary)--\r\n")
        return buf
    }

    /// Posts a bundle ZIP to /admin/courses/import.
    private func postImport(cookie: String, zipData: Data) async throws
        -> (status: HTTPStatus, body: String)
    {
        let boundary = "cb-boundary-\(UUID().uuidString)"
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.test(.POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = self.makeMultipartBody(fileData: zipData, boundary: boundary)
            }, afterResponse: { res in
                result = (res.status, res.body.string)
            }
        )
        return result
    }

    // MARK: - GET /admin/courses/:courseID/export

    func testExportRequiresAdmin() async throws {
        let cookie = try await loginAsStudent()
        let course = try await makeTestCourse(code: "EXP_AUTH")
        let id = try course.requireID().uuidString

        try await app.test(.GET, "/admin/courses/\(id)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in XCTAssertEqual(res.status, .forbidden) }
        )
    }

    func testExportNotFoundForUnknownCourse() async throws {
        let cookie = try await loginAsAdmin()
        try await app.test(.GET, "/admin/courses/\(UUID().uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in XCTAssertEqual(res.status, .notFound) }
        )
    }

    func testExportEmptyCourseReturnsZip() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeTestCourse(code: "EXP_EMPTY")
        let id = try course.requireID().uuidString

        try await app.test(.GET, "/admin/courses/\(id)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(
                    res.headers.first(name: .contentType)?.contains("zip") == true,
                    "Expected application/zip, got: \(res.headers.first(name: .contentType) ?? "(none)")"
                )
                XCTAssertTrue(res.headers.first(name: .contentDisposition)?.contains(".zip") == true)
            }
        )
    }

    func testExportManifestContainsCorrectCounts() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeTestCourse(code: "EXP_COUNTS")
        let courseID = try course.requireID()

        let setup = try await insertSetupWithZip(id: "setup_exp_c1", courseID: courseID)
        try await insertAssignment(testSetupID: setup.id!, courseID: courseID)

        var zipData = Data()
        try await app.test(.GET, "/admin/courses/\(courseID.uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                zipData = Data(res.body.readableBytesView)
            }
        )

        // Extract the ZIP and parse bundle.json
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("exp-verify-\(UUID().uuidString).zip").path
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exp-extract-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: zipPath)
            try? FileManager.default.removeItem(at: extractDir)
        }

        try zipData.write(to: URL(fileURLWithPath: zipPath))
        try await extractZipArchive(zipPath: zipPath, into: extractDir)

        let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.course.code, "EXP_COUNTS")
        XCTAssertEqual(manifest.testSetups.count, 1)
        XCTAssertEqual(manifest.assignments.count, 1)
        XCTAssertEqual(manifest.assignments.first?.title, "Test Lab")
        XCTAssertEqual(manifest.submissions.count, 0)
    }

    // MARK: - POST /admin/courses/import — access control

    func testImportRequiresAdmin() async throws {
        let cookie = try await loginAsStudent()
        let zipData = try await makeMinimalBundleZip(courseCode: "IMP_AUTH")
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertEqual(status, .forbidden)
    }

    // MARK: - POST /admin/courses/import — validation errors

    func testImportRejectsMissingBundleJSON() async throws {
        let cookie = try await loginAsAdmin()

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-no-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try "placeholder".write(to: stagingDir.appendingPathComponent("readme.txt"),
                                atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let zipData = try await zipDir(stagingDir)
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertEqual(status, .badRequest)
    }

    func testImportRejectsInvalidBundleJSON() async throws {
        let cookie = try await loginAsAdmin()

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-bad-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try "this is not json!!!".write(to: stagingDir.appendingPathComponent("bundle.json"),
                                        atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let zipData = try await zipDir(stagingDir)
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertEqual(status, .badRequest)
    }

    func testImportRejectsWrongSchemaVersion() async throws {
        let cookie = try await loginAsAdmin()

        let badJSON = """
        {"schemaVersion":99,"exportedAt":"2026-01-01T00:00:00Z","exportedBy":"admin",
         "chickadeeVersion":"0.2.0","course":{"code":"BADVER","name":"X"},
         "users":[],"enrolledUserBundleIDs":[],"assignments":[],
         "testSetups":[],"submissions":[],"results":[]}
        """
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-bad-ver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try badJSON.write(to: stagingDir.appendingPathComponent("bundle.json"),
                         atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let zipData = try await zipDir(stagingDir)
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertEqual(status, .badRequest)
    }

    func testImportRejectsMissingSetupFile() async throws {
        let cookie = try await loginAsAdmin()

        // Manifest references a setup zip that isn't in the archive
        let badJSON = """
        {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z","exportedBy":"admin",
         "chickadeeVersion":"0.2.0","course":{"code":"MISSING_FILE","name":"X"},
         "users":[],"enrolledUserBundleIDs":[],"assignments":[],
         "testSetups":[{"bundleID":"setup_1","originalID":"setup_ghost",
                        "manifest":"{}","zipFilename":"testsetups/setup_ghost.zip"}],
         "submissions":[],"results":[]}
        """
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-missing-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        // Deliberately NOT writing testsetups/setup_ghost.zip
        try badJSON.write(to: stagingDir.appendingPathComponent("bundle.json"),
                         atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let zipData = try await zipDir(stagingDir)
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertEqual(status, .badRequest)
    }

    func testImportRejectsActiveCourseDuplicate() async throws {
        let cookie = try await loginAsAdmin()
        _ = try await makeTestCourse(code: "DUPLICATE101") // active course

        let zipData = try await makeMinimalBundleZip(courseCode: "DUPLICATE101")
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertEqual(status, .conflict)
    }

    func testImportAllowsArchivedCourseDuplicate() async throws {
        let cookie = try await loginAsAdmin()
        let archived = try await makeTestCourse(code: "ARCHIVED_IMP")
        archived.isArchived = true
        try await archived.save(on: app.db)

        let zipData = try await makeMinimalBundleZip(courseCode: "ARCHIVED_IMP")
        let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
        // 500 expected (Leaf not configured), but NOT a 4xx rejection
        XCTAssertNotEqual(status, .conflict)
        XCTAssertNotEqual(status, .forbidden)
        XCTAssertNotEqual(status, .badRequest)
    }

    // MARK: - POST /admin/courses/import — DB record creation

    func testImportCreatesExpectedDBRecords() async throws {
        let cookie = try await loginAsAdmin()
        let zipData = try await makeMinimalBundleZip(courseCode: "IMP_RECORDS")

        let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertNotEqual(status, .badRequest, "Import failed: \(body.prefix(200))")
        XCTAssertNotEqual(status, .conflict)
        XCTAssertNotEqual(status, .forbidden)

        guard let course = try await APICourse.query(on: app.db)
            .filter(\.$code == "IMP_RECORDS").first()
        else {
            XCTFail("Imported course should exist in DB")
            return
        }
        let courseID = try course.requireID()
        let setups = try await APITestSetup.query(on: app.db)
            .filter(\.$courseID == courseID).all()
        XCTAssertEqual(setups.count, 1, "Expected 1 imported test setup")

        let assignments = try await APIAssignment.query(on: app.db)
            .filter(\.$courseID == courseID).all()
        XCTAssertEqual(assignments.count, 1, "Expected 1 imported assignment")
        XCTAssertEqual(assignments.first?.title, "Lab 1")
        XCTAssertEqual(assignments.first?.isOpen, false) // bundle sets isOpen: false
    }

    func testImportMatchesExistingUser() async throws {
        let cookie = try await loginAsAdmin()

        // Pre-create the user that the bundle will reference
        let hash = try Bcrypt.hash("existing-pw")
        let existingUser = APIUser(username: "cb_existing_student", passwordHash: hash, role: "student")
        try await existingUser.save(on: app.db)
        let existingID = try existingUser.requireID()
        let userCountBefore = try await APIUser.query(on: app.db).count()

        let zipData = try await makeBundleZipWithUser(
            courseCode: "USERMATCH_CB",
            username: "cb_existing_student"
        )
        let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertNotEqual(status, .forbidden, body)
        XCTAssertNotEqual(status, .badRequest, body)

        // No new user should have been created
        let userCountAfter = try await APIUser.query(on: app.db).count()
        XCTAssertEqual(userCountAfter, userCountBefore,
                       "No new user should be created when username already exists")

        // The enrollment should reference the pre-existing user
        let course = try await APICourse.query(on: app.db)
            .filter(\.$code == "USERMATCH_CB").first()
        XCTAssertNotNil(course)
        guard let courseID2 = try course?.requireID() else {
            XCTFail("Imported course USERMATCH_CB not found in DB")
            return
        }
        let enrollment = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == courseID2).first()
        XCTAssertEqual(enrollment?.userID, existingID,
                       "Enrollment should point to the pre-existing user")
    }

    func testImportCreatesPlaceholderUser() async throws {
        let cookie = try await loginAsAdmin()

        let zipData = try await makeBundleZipWithUser(
            courseCode: "PLACEHOLDER_CB",
            username: "cb_brand_new_user"
        )
        let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
        XCTAssertNotEqual(status, .forbidden, body)
        XCTAssertNotEqual(status, .badRequest, body)

        let placeholder = try await APIUser.query(on: app.db)
            .filter(\.$username == "cb_brand_new_user").first()
        XCTAssertNotNil(placeholder, "Placeholder user should be created")
        XCTAssertEqual(placeholder?.passwordHash, "",
                       "Placeholder user should have empty passwordHash (inert account)")
    }

    // MARK: - Round-trip: export → import

    func testRoundTripExportImport() async throws {
        let cookie = try await loginAsAdmin()

        // Set up source course
        let course = try await makeTestCourse(code: "ROUNDTRIP_CB")
        let courseID = try course.requireID()
        let setup = try await insertSetupWithZip(id: "setup_rt_cb1", courseID: courseID)
        try await insertAssignment(testSetupID: setup.id!, title: "RT Lab", courseID: courseID)

        // Export
        var exportedZip = Data()
        try await app.test(.GET, "/admin/courses/\(courseID.uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                exportedZip = Data(res.body.readableBytesView)
            }
        )
        XCTAssertFalse(exportedZip.isEmpty, "Exported ZIP should not be empty")

        // Archive the original so the import does not hit a 409
        course.isArchived = true
        try await course.save(on: app.db)

        // Import the exported ZIP
        let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
        XCTAssertNotEqual(status, .badRequest,  "Import should not fail: \(body.prefix(300))")
        XCTAssertNotEqual(status, .conflict,    body)
        XCTAssertNotEqual(status, .forbidden,   body)

        // Verify the imported course has the same structure
        guard let imported = try await APICourse.query(on: app.db)
            .filter(\.$code == "ROUNDTRIP_CB")
            .filter(\.$isArchived == false)
            .first()
        else {
            XCTFail("Imported course should exist and be active")
            return
        }
        let importedID = try imported.requireID()
        let importedSetups = try await APITestSetup.query(on: app.db)
            .filter(\.$courseID == importedID).all()
        XCTAssertEqual(importedSetups.count, 1, "Round-trip: expected 1 test setup")

        let importedAssignments = try await APIAssignment.query(on: app.db)
            .filter(\.$courseID == importedID).all()
        XCTAssertEqual(importedAssignments.count, 1, "Round-trip: expected 1 assignment")
        XCTAssertEqual(importedAssignments.first?.title, "RT Lab")
    }

    // MARK: - Bundle builder with a user (used by user-matching tests)

    private func makeBundleZipWithUser(courseCode: String, username: String) async throws -> Data {
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
            exportedAt:            Date(),
            exportedBy:            "test-admin",
            chickadeeVersion:      "0.2.0",
            course:                BundledCourse(code: courseCode, name: "User Test Course"),
            users:                 [BundledUser(bundleID: "user_1", username: username,
                                                displayName: nil, email: nil, role: "student")],
            enrolledUserBundleIDs: ["user_1"],
            assignments:           [],
            testSetups:            [BundledTestSetup(bundleID: "setup_1", originalID: setupOrigID,
                                                     manifest: Self.workerManifestJSON,
                                                     zipFilename: "testsetups/\(setupOrigID).zip")],
            submissions:           [],
            results:               []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: stagingDir.appendingPathComponent("bundle.json"))
        try Data(Self.dummyZipBytes).write(to: setupsDir.appendingPathComponent("\(setupOrigID).zip"))

        return try await zipDir(stagingDir)
    }
}
