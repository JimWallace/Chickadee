// Tests/APITests/CourseBundleTests.swift
//
// Integration tests for course bundle export and import.
//
//   GET  /admin/courses/:courseID/export  — stream a bundle ZIP (admin only)
//   POST /admin/courses/import            — accept an uploaded bundle ZIP (admin only)
//
// Closes #69 and #70.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtest")
    }

    // MARK: - Auth helpers

    private func loginAsAdmin() async throws -> String {
        return try await loginUser(username: "testadmin_cb", password: "testpassword", role: "admin", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "teststudent_cb", password: "testpassword", role: "student", on: app)
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
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        // Minimal valid ZIP end-of-central-directory record (22 bytes)
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            .write(to: URL(fileURLWithPath: zipPath))
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(
        testSetupID: String, title: String = "Test Lab",
        courseID: UUID
    ) async throws -> APIAssignment {
        let a = APIAssignment(
            testSetupID: testSetupID, title: title,
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
            exportedAt: Date(),
            exportedBy: "test-admin",
            chickadeeVersion: "0.2.0",
            course: BundledCourse(code: courseCode, name: "Minimal Import Course"),
            users: [],
            enrolledUserBundleIDs: [],
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
    private func zipDir(_ dir: URL) async throws -> Data {
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-out-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        try await createZipArchive(sourceDir: dir, outputPath: outPath)
        return try Data(contentsOf: URL(fileURLWithPath: outPath))
    }

    /// Constructs a multipart/form-data body with an optional CSRF token field and a "file" field.
    private func makeMultipartBody(fileData: Data, boundary: String, csrfToken: String? = nil) -> ByteBuffer {
        var buf = ByteBuffer()
        if let token = csrfToken {
            buf.writeString("--\(boundary)\r\n")
            buf.writeString("Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
            buf.writeString(token)
            buf.writeString("\r\n")
        }
        buf.writeString("--\(boundary)\r\n")
        buf.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        buf.writeString("Content-Type: application/zip\r\n\r\n")
        buf.writeBytes(fileData)
        buf.writeString("\r\n--\(boundary)--\r\n")
        return buf
    }

    /// Posts a bundle ZIP to /admin/courses/import, including a valid CSRF token.
    private func postImport(
        cookie: String, zipData: Data
    ) async throws
        -> (status: HTTPStatus, body: String)
    {
        // Fetch a CSRF token bound to this session before submitting the form.
        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let boundary = "cb-boundary-\(UUID().uuidString)"
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = self.makeMultipartBody(fileData: zipData, boundary: boundary, csrfToken: csrf)
            },
            afterResponse: { res in
                result = (res.status, res.body.string)
            }
        )
        return result
    }

    // MARK: - GET /admin/courses/:courseID/export

    @Test func exportRequiresAdmin() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let course = try await makeTestCourse(code: "EXP_AUTH")
            let id = try course.requireID().uuidString

            try await app.asyncTest(
                .GET, "/admin/courses/\(id)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .forbidden) }
            )

        }
    }

    @Test func exportNotFoundForUnknownCourse() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin/courses/\(UUID().uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .notFound) }
            )

        }
    }

    @Test func exportEmptyCourseReturnsZip() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(code: "EXP_EMPTY")
            let id = try course.requireID().uuidString

            try await app.asyncTest(
                .GET, "/admin/courses/\(id)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(
                        res.headers.first(name: .contentType)?.contains("zip") == true,
                        "Expected application/zip, got: \(res.headers.first(name: .contentType) ?? "(none)")"
                    )
                    #expect(res.headers.first(name: .contentDisposition)?.contains(".zip") == true)
                }
            )

        }
    }

    @Test func exportManifestContainsCorrectCounts() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(code: "EXP_COUNTS")
            let courseID = try course.requireID()

            let setup = try await insertSetupWithZip(id: "setup_exp_c1", courseID: courseID)
            try await insertAssignment(testSetupID: (try setup.requireID()), courseID: courseID)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
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

            #expect(manifest.schemaVersion == 1)
            #expect(manifest.course.code == "EXP_COUNTS")
            #expect(manifest.testSetups.count == 1)
            #expect(manifest.assignments.count == 1)
            #expect(manifest.assignments.first?.title == "Test Lab")
            #expect(manifest.submissions.isEmpty)

        }
    }

    // MARK: - POST /admin/courses/import — access control

    @Test func importRequiresAdmin() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let zipData = try await makeMinimalBundleZip(courseCode: "IMP_AUTH")
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .forbidden)

        }
    }

    // MARK: - POST /admin/courses/import — validation errors

    @Test func importRejectsMissingBundleJSON() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-no-manifest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try "placeholder".write(
                to: stagingDir.appendingPathComponent("readme.txt"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsInvalidBundleJSON() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-bad-json-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try "this is not json!!!".write(
                to: stagingDir.appendingPathComponent("bundle.json"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsWrongSchemaVersion() async throws {
        try await withApp(app) { _ in
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
            try badJSON.write(
                to: stagingDir.appendingPathComponent("bundle.json"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsMissingSetupFile() async throws {
        try await withApp(app) { _ in
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
            try badJSON.write(
                to: stagingDir.appendingPathComponent("bundle.json"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsActiveCourseDuplicate() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestCourse(code: "DUPLICATE101")  // active course

            let zipData = try await makeMinimalBundleZip(courseCode: "DUPLICATE101")
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .conflict)

        }
    }

    @Test func importAllowsArchivedCourseDuplicate() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let archived = try await makeTestCourse(code: "ARCHIVED_IMP")
            archived.isArchived = true
            try await archived.save(on: app.db)

            let zipData = try await makeMinimalBundleZip(courseCode: "ARCHIVED_IMP")
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            // 500 expected (Leaf not configured), but NOT a 4xx rejection
            #expect(status != .conflict)
            #expect(status != .forbidden)
            #expect(status != .badRequest)

        }
    }

    // MARK: - POST /admin/courses/import — DB record creation

    @Test func importCreatesExpectedDBRecords() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let zipData = try await makeMinimalBundleZip(courseCode: "IMP_RECORDS")

            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")
            #expect(status != .conflict)
            #expect(status != .forbidden)

            guard
                let course = try await APICourse.query(on: app.db)
                    .filter(\.$code == "IMP_RECORDS").first()
            else {
                Issue.record("Imported course should exist in DB")
                return
            }
            let courseID = try course.requireID()
            let setups = try await APITestSetup.query(on: app.db)
                .filter(\.$courseID == courseID).all()
            #expect(setups.count == 1, "Expected 1 imported test setup")

            let assignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == courseID).all()
            #expect(assignments.count == 1, "Expected 1 imported assignment")
            #expect(assignments.first?.title == "Lab 1")
            #expect(assignments.first?.isOpen == false)  // bundle sets isOpen: false

        }
    }

    /// A bundle exported by an older build carries no language declaration.
    /// Import must supply one, because import is otherwise a permanent source of
    /// undeclared assignments — and "undeclared" is precisely the state the
    /// worker has to be able to refuse rather than guess at. A refusal that
    /// legitimate imports can trip is one that has to be watered down.
    @Test func importDeclaresALanguageForAnUndeclaredBundle() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let zipData = try await makeMinimalBundleZip(courseCode: "IMP_LANG")

            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "IMP_LANG").first())
            let setup = try #require(
                try await APITestSetup.query(on: app.db)
                    .filter(\.$courseID == course.requireID()).first())
            let manifest = try #require(setup.decodedManifest())

            #expect(
                manifest.languageDeclared == true,
                "an imported setup must carry a declaration, whatever the bundle said")
            // The fixture's suite is `.sh`, so the truthful declaration is "no
            // language" — recorded as the flag with no `language` beside it,
            // which is exactly what distinguishes it from never having asked.
            #expect(manifest.language == nil)
        }
    }

    @Test func importMatchesExistingUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            // Pre-create the user that the bundle will reference
            let hash = try testPasswordHash("existing-pw")
            let existingUser = APIUser(username: "cb_existing_student", passwordHash: hash, role: "student")
            try await existingUser.save(on: app.db)
            let existingID = try existingUser.requireID()
            let userCountBefore = try await APIUser.query(on: app.db).count()

            let zipData = try await makeBundleZipWithUser(
                courseCode: "USERMATCH_CB",
                username: "cb_existing_student"
            )
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .forbidden, "\(body)")
            #expect(status != .badRequest, "\(body)")

            // No new user should have been created
            let userCountAfter = try await APIUser.query(on: app.db).count()
            #expect(userCountAfter == userCountBefore, "No new user should be created when username already exists")

            // The enrollment should reference the pre-existing user
            let course = try await APICourse.query(on: app.db)
                .filter(\.$code == "USERMATCH_CB").first()
            #expect(course != nil)
            guard let courseID2 = try course?.requireID() else {
                Issue.record("Imported course USERMATCH_CB not found in DB")
                return
            }
            let enrollment = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID2).first()
            #expect(enrollment?.userID == existingID, "Enrollment should point to the pre-existing user")

        }
    }

    @Test func importCreatesPlaceholderUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            let zipData = try await makeBundleZipWithUser(
                courseCode: "PLACEHOLDER_CB",
                username: "cb_brand_new_user"
            )
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .forbidden, "\(body)")
            #expect(status != .badRequest, "\(body)")

            let placeholder = try await APIUser.query(on: app.db)
                .filter(\.$username == "cb_brand_new_user").first()
            #expect(placeholder != nil, "Placeholder user should be created")
            #expect(
                placeholder?.passwordHash.isEmpty == true,
                "Placeholder user should have empty passwordHash (inert account)"
            )

        }
    }

    // MARK: - Round-trip: export → import

    @Test func roundTripExportImport() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            // Set up source course
            let course = try await makeTestCourse(code: "ROUNDTRIP_CB")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_rt_cb1", courseID: courseID)
            try await insertAssignment(testSetupID: (try setup.requireID()), title: "RT Lab", courseID: courseID)

            // Export
            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                }
            )
            #expect(exportedZip.isEmpty == false, "Exported ZIP should not be empty")

            // Archive the original so the import does not hit a 409
            course.isArchived = true
            try await course.save(on: app.db)

            // Import the exported ZIP
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "Import should not fail: \(body.prefix(300))")
            #expect(status != .conflict, "\(body)")
            #expect(status != .forbidden, "\(body)")

            // Verify the imported course has the same structure
            guard
                let imported = try await APICourse.query(on: app.db)
                    .filter(\.$code == "ROUNDTRIP_CB")
                    .filter(\.$isArchived == false)
                    .first()
            else {
                Issue.record("Imported course should exist and be active")
                return
            }
            let importedID = try imported.requireID()
            let importedSetups = try await APITestSetup.query(on: app.db)
                .filter(\.$courseID == importedID).all()
            #expect(importedSetups.count == 1, "Round-trip: expected 1 test setup")

            let importedAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == importedID).all()
            #expect(importedAssignments.count == 1, "Round-trip: expected 1 assignment")
            #expect(importedAssignments.first?.title == "RT Lab")

        }
    }

    // MARK: - Round-trip: sections preserved through export → import

    @Test func roundTripPreservesSections() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            let course = try await makeTestCourse(code: "RT_SECTS")
            let courseID = try course.requireID()

            // Two sections with distinct grading modes.
            let browserSec = APICourseSection(
                name: "Browser Labs", defaultGradingMode: "browser",
                sortOrder: 1, courseID: courseID)
            try await browserSec.save(on: app.db)
            let workerSec = APICourseSection(
                name: "Worker Labs", defaultGradingMode: "worker",
                sortOrder: 2, courseID: courseID)
            try await workerSec.save(on: app.db)

            let setup1 = try await insertSetupWithZip(id: "rt_sects_s1", courseID: courseID)
            let setup2 = try await insertSetupWithZip(id: "rt_sects_s2", courseID: courseID)

            let a1 = APIAssignment(
                testSetupID: try #require(setup1.id), title: "Browser Lab",
                isOpen: false, sectionID: try browserSec.requireID(),
                courseID: courseID)
            try await a1.save(on: app.db)
            let a2 = APIAssignment(
                testSetupID: try #require(setup2.id), title: "Worker Lab",
                isOpen: false, sectionID: try workerSec.requireID(),
                courseID: courseID)
            try await a2.save(on: app.db)

            // Export.
            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })
            #expect(!exportedZip.isEmpty)

            // Inspect the raw manifest to confirm sections + sectionBundleIDs.
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-sects-ext-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            let zipVerifyPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-sects-\(UUID().uuidString).zip").path
            defer { try? FileManager.default.removeItem(atPath: zipVerifyPath) }
            try exportedZip.write(to: URL(fileURLWithPath: zipVerifyPath))
            try await extractZipArchive(zipPath: zipVerifyPath, into: extractDir)

            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)

            #expect(manifest.sections?.count == 2, "Manifest should include 2 sections")
            #expect(
                manifest.assignments.allSatisfy { $0.sectionBundleID != nil },
                "Every assignment in the manifest should carry a sectionBundleID")

            // Archive the original so import doesn't collide.
            course.isArchived = true
            try await course.save(on: app.db)

            // Import.
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "Import should not fail: \(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_SECTS")
                    .filter(\.$isArchived == false)
                    .first(),
                "Imported course not found")
            let importedID = try imported.requireID()

            // Sections recreated with correct names and grading modes.
            let importedSections = try await APICourseSection.query(on: app.db)
                .filter(\.$courseID == importedID)
                .sort(\.$sortOrder)
                .all()
            #expect(importedSections.count == 2, "Imported course should have 2 sections")
            #expect(importedSections.first?.name == "Browser Labs")
            #expect(importedSections.first?.defaultGradingMode == "browser")
            #expect(importedSections.last?.name == "Worker Labs")
            #expect(importedSections.last?.defaultGradingMode == "worker")

            // All assignments placed in a section, not ungrouped.
            let importedAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == importedID)
                .all()
            #expect(importedAssignments.count == 2)
            #expect(
                importedAssignments.allSatisfy { $0.sectionID != nil },
                "All imported assignments should have a sectionID")
        }
    }

    // MARK: - Round-trip: content items preserved through export → import

    @Test func roundTripPreservesContentItems() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(code: "RT_CONTENT")
            let courseID = try course.requireID()

            let section = APICourseSection(
                name: "Lectures", defaultGradingMode: "worker", sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)

            // One sectioned item (two links) + one ungrouped, hidden item.
            let sectioned = APICourseContentItem(
                courseID: courseID, sectionID: try section.requireID(), sortOrder: 1,
                title: "Lecture 1", kind: .notebook, itemDescription: "Intro",
                links: [
                    ContentLink(label: "PDF", url: "https://example.com/l1.pdf"),
                    ContentLink(label: "NB", url: "/materials/l1.ipynb"),
                ],
                updatedLabel: "2026-05-11", isPublished: true)
            try await sectioned.save(on: app.db)
            let ungrouped = APICourseContentItem(
                courseID: courseID, sectionID: nil, sortOrder: 1, title: "Outline",
                kind: .outline, links: [ContentLink(label: "Link", url: "https://example.com/o")],
                isPublished: false)
            try await ungrouped.save(on: app.db)

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })

            // Inspect the raw manifest.
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-content-ext-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            let zipVerifyPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-content-\(UUID().uuidString).zip").path
            defer { try? FileManager.default.removeItem(atPath: zipVerifyPath) }
            try exportedZip.write(to: URL(fileURLWithPath: zipVerifyPath))
            try await extractZipArchive(zipPath: zipVerifyPath, into: extractDir)
            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)
            #expect(manifest.contentItems?.count == 2)
            let bundledSectioned = try #require(manifest.contentItems?.first { $0.title == "Lecture 1" })
            #expect(bundledSectioned.sectionBundleID != nil)
            #expect(bundledSectioned.links.count == 2)
            let bundledUngrouped = try #require(manifest.contentItems?.first { $0.title == "Outline" })
            #expect(bundledUngrouped.sectionBundleID == nil)
            #expect(bundledUngrouped.isPublished == false)

            // Archive + import into a fresh course.
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "\(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_CONTENT").filter(\.$isArchived == false).first())
            let importedItems = try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == imported.requireID()).sort(\.$sortOrder).all()
            #expect(importedItems.count == 2)
            let importedSectioned = try #require(importedItems.first { $0.title == "Lecture 1" })
            #expect(importedSectioned.sectionID != nil, "sectioned item should keep its section link")
            #expect(importedSectioned.links.count == 2)
            #expect(importedSectioned.kind == .notebook)
            let importedUngrouped = try #require(importedItems.first { $0.title == "Outline" })
            #expect(importedUngrouped.sectionID == nil)
            #expect(importedUngrouped.isPublished == false)
        }
    }

    @Test func roundTripPreservesContentAttachments() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(code: "RT_ATTACH")
            let courseID = try course.requireID()

            let item = APICourseContentItem(
                courseID: courseID, sortOrder: 1, title: "Slides", kind: .slides, isPublished: true)
            try await item.save(on: app.db)
            let itemID = try item.requireID()
            let bytes = Data("SLIDE-DECK-BYTES".utf8)
            let attachment = try await ContentAttachmentStore.store(
                bytes: bytes, originalName: "week1.pdf", label: "Week 1", sortOrder: 1,
                itemID: itemID, on: Request(application: app, on: app.eventLoopGroup.any()))
            item.attachments = [attachment]
            try await item.save(on: app.db)

            var exportedZip = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    exportedZip = Data(res.body.readableBytesView)
                })

            // Manifest carries the attachment metadata + the bytes are in the zip.
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-attach-ext-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            let zipVerifyPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-attach-\(UUID().uuidString).zip").path
            defer { try? FileManager.default.removeItem(atPath: zipVerifyPath) }
            try exportedZip.write(to: URL(fileURLWithPath: zipVerifyPath))
            try await extractZipArchive(zipPath: zipVerifyPath, into: extractDir)
            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)
            let bundledItem = try #require(manifest.contentItems?.first { $0.title == "Slides" })
            let bundledAtt = try #require(bundledItem.attachments?.first)
            #expect(bundledAtt.originalName == "week1.pdf")
            #expect(bundledAtt.label == "Week 1")
            let contentFile = extractDir.appendingPathComponent(bundledAtt.bundleFilename)
            #expect(try Data(contentsOf: contentFile) == bytes)

            // Archive + import into a fresh course; the file bytes survive under
            // a regenerated attachment id.
            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: exportedZip)
            #expect(status != .badRequest, "\(body.prefix(300))")
            #expect(status != .conflict, "\(body.prefix(300))")

            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "RT_ATTACH").filter(\.$isArchived == false).first())
            let importedItem = try #require(
                try await APICourseContentItem.query(on: app.db)
                    .filter(\.$courseID == imported.requireID()).first())
            let importedAtt = try #require(importedItem.attachments.first)
            #expect(importedAtt.originalName == "week1.pdf")
            #expect(importedAtt.id != attachment.id, "attachment id is regenerated on import")
            let importedPath = ContentAttachmentStore.path(
                app, itemID: try importedItem.requireID(), attachmentID: importedAtt.id)
            #expect(try Data(contentsOf: URL(fileURLWithPath: importedPath)) == bytes)
        }
    }

    /// A bundle exported before content items existed omits the key entirely;
    /// it must decode (contentItems == nil) and import without error. Wrapped in
    /// `withApp` so the per-test app created in `init()` shuts down cleanly.
    @Test func manifestWithoutContentItemsDecodesToNil() async throws {
        try await withApp(app) { _ in
            let json = """
                {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z","exportedBy":"admin",
                 "chickadeeVersion":"0.0.0","course":{"code":"OLD","name":"Old"},
                 "users":[],"enrolledUserBundleIDs":[],"assignments":[],"testSetups":[],
                 "submissions":[],"results":[]}
                """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: Data(json.utf8))
            #expect(manifest.contentItems == nil)
            #expect(manifest.sections == nil)
        }
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
