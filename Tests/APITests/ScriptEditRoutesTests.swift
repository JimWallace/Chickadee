// Tests/APITests/ScriptEditRoutesTests.swift
//
// Integration tests for the script CRUD endpoints:
//
//   GET    /instructor/:assignmentID/scripts/:filename
//   PUT    /instructor/:assignmentID/scripts/:filename
//   POST   /instructor/:assignmentID/scripts
//   DELETE /instructor/:assignmentID/scripts/:filename

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class ScriptEditRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-scripts-\(UUID().uuidString)/")
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
        app.migrations.add(AddCourseSections())
        app.migrations.add(AddCourseOpenEnrollment())
        app.migrations.add(AddCourseEnrollmentMode())
        try await app.autoMigrate()

        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        return try await loginUser(username: "testinstructor_scripts", password: "testpassword",
                                   role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "teststudent_scripts", password: "testpassword",
                                   role: "student", on: app)
    }

    // MARK: - DB/fixture helpers

    private func makeTestCourseID() async throws -> UUID {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "SCR101").first() {
            return try existing.requireID()
        }
        let course = APICourse(code: "SCR101", name: "Script Test Course")
        try await course.save(on: app.db)
        return try course.requireID()
    }

    @discardableResult
    private func insertSetup(id: String, withEntries entries: [(name: String, content: String)] = []) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """
        let courseID = try await makeTestCourseID()
        let zipPath = tmpDir + "testsetups/\(id).zip"
        try makeZipAt(zipPath: zipPath, entries: entries)
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String) async throws -> APIAssignment {
        let courseID = try await makeTestCourseID()
        let a = APIAssignment(testSetupID: testSetupID, title: title, dueAt: nil, isOpen: true,
                               courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    /// Creates a zip at `zipPath` containing the given entries.
    /// Skips the test if Python 3 is unavailable (same pattern as ZipArchiverTests).
    private func makeZipAt(zipPath: String, entries: [(name: String, content: String)]) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/env") else {
            throw XCTSkip("env not available")
        }
        // An empty zip can be made with a dummy entry then deleted, but it's easier
        // to always include a placeholder if no entries are given.
        let allEntries = entries.isEmpty
            ? [("test_runtime.py", "# placeholder\n")]
            : entries
        let entriesCode = allEntries.map { e in
            "z.writestr(\(e.name.debugDescription), \(e.content.debugDescription))"
        }.joined(separator: "\n    ")
        let script = """
import zipfile
with zipfile.ZipFile('\(zipPath)', 'w') as z:
    \(entriesCode)
"""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("python3 not available or failed to create zip")
        }
    }

    // MARK: - GET /instructor/:assignmentID/scripts/:filename

    func testGetScriptReturnsContentForInstructor() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "sc_get1", withEntries: [
            ("test_foo.py", "print('hello')\n")
        ])
        let a = try await insertAssignment(testSetupID: "sc_get1", title: "GetTest")
        let id = a.publicID

        try await app.asyncTest(.GET, "/instructor/\(id)/scripts/test_foo.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains("print('hello')"),
                              "Expected script content in response, got: \(res.body.string.prefix(200))")
            }
        )
    }

    func testGetScriptReturns404ForUnknownFile() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "sc_get2", withEntries: [("test_a.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_get2", title: "GetMissing")
        let id = a.publicID

        try await app.asyncTest(.GET, "/instructor/\(id)/scripts/does_not_exist.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    func testGetScriptReturns403ForStudent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "sc_get3", withEntries: [("test_a.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_get3", title: "GetStudent")
        let id = a.publicID

        try await app.asyncTest(.GET, "/instructor/\(id)/scripts/test_a.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }

    func testGetScriptReturns404ForUnknownAssignment() async throws {
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/zzzzzzzzz/scripts/test_a.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                // Invalid public ID format → 404 (from parameter validation)
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    // MARK: - PUT /instructor/:assignmentID/scripts/:filename

    func testPutScriptUpdatesContent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        let setup = try await insertSetup(id: "sc_put1", withEntries: [("test_bar.py", "# old\n")])
        let a = try await insertAssignment(testSetupID: "sc_put1", title: "PutTest")
        let id = a.publicID

        try await app.asyncTest(.PUT, "/instructor/\(id)/scripts/test_bar.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"content\":\"# new content\\n\"}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .noContent)
            }
        )

        // Verify the zip on disk was updated.
        let content = readScriptFromZip(zipPath: setup.zipPath, filename: "test_bar.py")
        XCTAssertEqual(content, "# new content\n", "Expected updated content in zip, got: \(content ?? "nil")")
    }

    func testPutScriptReturns404ForMissingFile() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        try await insertSetup(id: "sc_put2", withEntries: [("test_bar.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_put2", title: "PutMissing")
        let id = a.publicID

        try await app.asyncTest(.PUT, "/instructor/\(id)/scripts/nonexistent.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"content\":\"# x\\n\"}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    func testPutScriptReturns403ForStudent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "sc_put3", withEntries: [("test_a.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_put3", title: "PutStudent")
        let id = a.publicID

        try await app.asyncTest(.PUT, "/instructor/\(id)/scripts/test_a.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"content\":\"# x\\n\"}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }

    // MARK: - POST /instructor/:assignmentID/scripts

    func testPostScriptCreatesNewFileInZip() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        let setup = try await insertSetup(id: "sc_post1", withEntries: [])
        let a = try await insertAssignment(testSetupID: "sc_post1", title: "PostTest")
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/scripts",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"filename\":\"test_new.py\",\"content\":\"# new script\\n\",\"tier\":\"public\",\"points\":1}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .created)
                let bodyStr = res.body.string
                XCTAssertTrue(bodyStr.contains("test_new.py"),
                              "Response should contain filename, got: \(bodyStr.prefix(200))")
            }
        )

        let content = readScriptFromZip(zipPath: setup.zipPath, filename: "test_new.py")
        XCTAssertEqual(content, "# new script\n", "New file should be in the zip")
    }

    func testPostScriptAddsEntryToManifest() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        _ = try await insertSetup(id: "sc_post2", withEntries: [])
        let a = try await insertAssignment(testSetupID: "sc_post2", title: "PostManifest")
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/scripts",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"filename\":\"test_mani.py\",\"content\":\"pass\\n\",\"tier\":\"release\",\"points\":2}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .created)
            }
        )

        // Reload setup from DB — manifest should now contain the new entry.
        let updated = try await APITestSetup.find("sc_post2", on: app.db)!
        XCTAssertTrue(updated.manifest.contains("test_mani.py"),
                      "Manifest should contain new entry, got: \(updated.manifest)")
        XCTAssertTrue(updated.manifest.contains("\"release\""),
                      "Manifest should contain tier 'release', got: \(updated.manifest)")
    }

    func testPostScriptReturns409ForDuplicate() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        try await insertSetup(id: "sc_post3", withEntries: [("test_existing.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_post3", title: "PostDupe")
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/scripts",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"filename\":\"test_existing.py\",\"content\":\"# new\\n\"}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .conflict)
            }
        )
    }

    func testPostScriptReturns400ForInvalidFilename() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        try await insertSetup(id: "sc_post4", withEntries: [])
        let a = try await insertAssignment(testSetupID: "sc_post4", title: "PostBadName")
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/scripts",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"filename\":\"../evil.sh\",\"content\":\"rm -rf /\\n\"}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .badRequest)
            }
        )
    }

    func testPostScriptReturns403ForStudent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "sc_post5", withEntries: [])
        let a = try await insertAssignment(testSetupID: "sc_post5", title: "PostStudent")
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/scripts",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "{\"filename\":\"test_x.py\",\"content\":\"pass\\n\"}")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }

    // MARK: - DELETE /instructor/:assignmentID/scripts/:filename

    func testDeleteScriptRemovesFileFromZip() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        let setup = try await insertSetup(id: "sc_del1", withEntries: [
            ("test_del.py", "pass\n"),
            ("support.py", "# helper\n")
        ])
        let a = try await insertAssignment(testSetupID: "sc_del1", title: "DeleteTest")
        let id = a.publicID

        try await app.asyncTest(.DELETE, "/instructor/\(id)/scripts/test_del.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .noContent)
            }
        )

        let content = readScriptFromZip(zipPath: setup.zipPath, filename: "test_del.py")
        XCTAssertNil(content, "Deleted file should no longer be in zip")

        let remaining = readScriptFromZip(zipPath: setup.zipPath, filename: "support.py")
        XCTAssertNotNil(remaining, "Other files should remain in zip")
    }

    func testDeleteScriptRemovesManifestEntry() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        // Include a second file so the zip is not empty after the delete.
        try await insertSetup(id: "sc_del2", withEntries: [
            ("test_rm.py", "pass\n"),
            ("support.py", "# helper\n")
        ])

        // Manually add a manifest entry for the script.
        let setup = try await APITestSetup.find("sc_del2", on: app.db)!
        setup.manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"script":"test_rm.py","tier":"public","order":1,"dependsOn":[],"points":1}],"timeLimitSeconds":10,"makefile":null}
        """
        try await setup.save(on: app.db)

        let a = try await insertAssignment(testSetupID: "sc_del2", title: "DeleteManifest")
        let id = a.publicID

        try await app.asyncTest(.DELETE, "/instructor/\(id)/scripts/test_rm.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .noContent)
            }
        )

        let updated = try await APITestSetup.find("sc_del2", on: app.db)!
        XCTAssertFalse(updated.manifest.contains("test_rm.py"),
                       "Manifest should no longer contain deleted script, got: \(updated.manifest)")
    }

    func testDeleteScriptReturns409WhenDependentsExist() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        try await insertSetup(id: "sc_del3", withEntries: [
            ("test_a.py", "pass\n"),
            ("test_b.py", "pass\n")
        ])

        // test_b depends on test_a.
        let setup = try await APITestSetup.find("sc_del3", on: app.db)!
        setup.manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[
          {"script":"test_a.py","tier":"public","order":1,"dependsOn":[],"points":1},
          {"script":"test_b.py","tier":"public","order":2,"dependsOn":["test_a.py"],"points":1}
        ],"timeLimitSeconds":10,"makefile":null}
        """
        try await setup.save(on: app.db)

        let a = try await insertAssignment(testSetupID: "sc_del3", title: "DeleteConflict")
        let id = a.publicID

        try await app.asyncTest(.DELETE, "/instructor/\(id)/scripts/test_a.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .conflict)
            }
        )
    }

    func testDeleteScriptReturns404ForMissingFile() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        try await insertSetup(id: "sc_del4", withEntries: [("test_a.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_del4", title: "DeleteMissing")
        let id = a.publicID

        try await app.asyncTest(.DELETE, "/instructor/\(id)/scripts/nonexistent.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    func testDeleteScriptReturns403ForStudent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
              FileManager.default.fileExists(atPath: "/usr/bin/zip") else {
            throw XCTSkip("zip/unzip not available")
        }
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "sc_del5", withEntries: [("test_a.py", "pass\n")])
        let a = try await insertAssignment(testSetupID: "sc_del5", title: "DeleteStudent")
        let id = a.publicID

        try await app.asyncTest(.DELETE, "/instructor/\(id)/scripts/test_a.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }
}
