// Tests/APITests/ScriptEditRoutesTests.swift
//
// Integration tests for the script CRUD endpoints:
//
//   GET    /instructor/:assignmentID/scripts/:filename
//   PUT    /instructor/:assignmentID/scripts/:filename
//   POST   /instructor/:assignmentID/scripts
//   DELETE /instructor/:assignmentID/scripts/:filename

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class ScriptEditRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-scripts")
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        return try await loginUser(
            username: "testinstructor_scripts", password: "testpassword",
            role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(
            username: "teststudent_scripts", password: "testpassword",
            role: "student", on: app)
    }

    // MARK: - DB/fixture helpers

    @discardableResult
    private func insertSetup(
        id: String, withEntries entries: [(name: String, content: String)] = []
    ) async throws -> APITestSetup {
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let courseID = try await app.testCourseID(code: "SCR101", name: "Script Test Course")
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        try makeZipAt(zipPath: zipPath, entries: entries)
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String) async throws -> APIAssignment {
        let courseID = try await app.testCourseID(code: "SCR101", name: "Script Test Course")
        let a = APIAssignment(
            testSetupID: testSetupID, title: title, dueAt: nil, isOpen: true,
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
        let allEntries =
            entries.isEmpty
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
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("python3 not available or failed to create zip")
        }
    }

    // MARK: - GET /instructor/:assignmentID/scripts/:filename

    @Test func getScriptReturnsContentForInstructor() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            try await insertSetup(
                id: "sc_get1",
                withEntries: [
                    ("test_foo.py", "print('hello')\n")
                ])
            let a = try await insertAssignment(testSetupID: "sc_get1", title: "GetTest")
            let id = a.publicID

            try await app.asyncTest(
                .GET, "/instructor/\(id)/scripts/test_foo.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(
                        res.body.string.contains("print('hello')"),
                        "Expected script content in response, got: \(res.body.string.prefix(200))")
                }
            )

        }
    }

    @Test func getScriptReturns404ForUnknownFile() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            try await insertSetup(id: "sc_get2", withEntries: [("test_a.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_get2", title: "GetMissing")
            let id = a.publicID

            try await app.asyncTest(
                .GET, "/instructor/\(id)/scripts/does_not_exist.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                }
            )

        }
    }

    @Test func getScriptReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "sc_get3", withEntries: [("test_a.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_get3", title: "GetStudent")
            let id = a.publicID

            try await app.asyncTest(
                .GET, "/instructor/\(id)/scripts/test_a.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }

    @Test func getScriptReturns404ForUnknownAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()

            try await app.asyncTest(
                .GET, "/instructor/zzzzzzzzz/scripts/test_a.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    // Invalid public ID format → 404 (from parameter validation)
                    #expect(res.status == .notFound)
                }
            )

        }
    }

    // MARK: - PUT /instructor/:assignmentID/scripts/:filename

    @Test func putScriptUpdatesContent() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let setup = try await insertSetup(id: "sc_put1", withEntries: [("test_bar.py", "# old\n")])
            let a = try await insertAssignment(testSetupID: "sc_put1", title: "PutTest")
            let id = a.publicID

            try await app.asyncTest(
                .PUT, "/instructor/\(id)/scripts/test_bar.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"content\":\"# new content\\n\"}")
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            // Verify the zip on disk was updated.
            let content = readScriptFromZip(zipPath: setup.zipPath, filename: "test_bar.py")
            #expect(content == "# new content\n", "Expected updated content in zip, got: \(content ?? "nil")")

        }
    }

    @Test func putScriptReturns404ForMissingFile() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "sc_put2", withEntries: [("test_bar.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_put2", title: "PutMissing")
            let id = a.publicID

            try await app.asyncTest(
                .PUT, "/instructor/\(id)/scripts/nonexistent.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"content\":\"# x\\n\"}")
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                }
            )

        }
    }

    @Test func putScriptReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "sc_put3", withEntries: [("test_a.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_put3", title: "PutStudent")
            let id = a.publicID

            try await app.asyncTest(
                .PUT, "/instructor/\(id)/scripts/test_a.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"content\":\"# x\\n\"}")
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }

    // MARK: - POST /instructor/:assignmentID/scripts

    @Test func postScriptCreatesNewFileInZip() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let setup = try await insertSetup(id: "sc_post1", withEntries: [])
            let a = try await insertAssignment(testSetupID: "sc_post1", title: "PostTest")
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/scripts",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(
                        string:
                            "{\"filename\":\"test_new.py\",\"content\":\"# new script\\n\",\"tier\":\"public\",\"points\":1}"
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .created)
                    let bodyStr = res.body.string
                    #expect(
                        bodyStr.contains("test_new.py"),
                        "Response should contain filename, got: \(bodyStr.prefix(200))")
                }
            )

            let content = readScriptFromZip(zipPath: setup.zipPath, filename: "test_new.py")
            #expect(content == "# new script\n", "New file should be in the zip")

        }
    }

    @Test func postScriptAddsEntryToManifest() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            _ = try await insertSetup(id: "sc_post2", withEntries: [])
            let a = try await insertAssignment(testSetupID: "sc_post2", title: "PostManifest")
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/scripts",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(
                        string:
                            "{\"filename\":\"test_mani.py\",\"content\":\"pass\\n\",\"tier\":\"release\",\"points\":2}")
                },
                afterResponse: { res in
                    #expect(res.status == .created)
                }
            )

            // Reload setup from DB — manifest should now contain the new entry.
            let updated = try #require(try await APITestSetup.find("sc_post2", on: app.db))
            #expect(
                updated.manifest.contains("test_mani.py"),
                "Manifest should contain new entry, got: \(updated.manifest)")
            #expect(
                updated.manifest.contains("\"release\""),
                "Manifest should contain tier 'release', got: \(updated.manifest)")

        }
    }

    @Test func postScriptReturns409ForDuplicate() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "sc_post3", withEntries: [("test_existing.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_post3", title: "PostDupe")
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/scripts",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"filename\":\"test_existing.py\",\"content\":\"# new\\n\"}")
                },
                afterResponse: { res in
                    #expect(res.status == .conflict)
                }
            )

        }
    }

    @Test func postScriptReturns400ForInvalidFilename() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "sc_post4", withEntries: [])
            let a = try await insertAssignment(testSetupID: "sc_post4", title: "PostBadName")
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/scripts",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"filename\":\"../evil.sh\",\"content\":\"rm -rf /\\n\"}")
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            )

        }
    }

    @Test func postScriptReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "sc_post5", withEntries: [])
            let a = try await insertAssignment(testSetupID: "sc_post5", title: "PostStudent")
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/scripts",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"filename\":\"test_x.py\",\"content\":\"pass\\n\"}")
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }

    // MARK: - DELETE /instructor/:assignmentID/scripts/:filename

    @Test func deleteScriptRemovesFileFromZip() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let setup = try await insertSetup(
                id: "sc_del1",
                withEntries: [
                    ("test_del.py", "pass\n"),
                    ("support.py", "# helper\n"),
                ])
            let a = try await insertAssignment(testSetupID: "sc_del1", title: "DeleteTest")
            let id = a.publicID

            try await app.asyncTest(
                .DELETE, "/instructor/\(id)/scripts/test_del.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            let content = readScriptFromZip(zipPath: setup.zipPath, filename: "test_del.py")
            #expect(content == nil, "Deleted file should no longer be in zip")

            let remaining = readScriptFromZip(zipPath: setup.zipPath, filename: "support.py")
            #expect(remaining != nil, "Other files should remain in zip")

        }
    }

    @Test func deleteScriptRemovesManifestEntry() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            // Include a second file so the zip is not empty after the delete.
            try await insertSetup(
                id: "sc_del2",
                withEntries: [
                    ("test_rm.py", "pass\n"),
                    ("support.py", "# helper\n"),
                ])

            // Manually add a manifest entry for the script.
            let setup = try #require(try await APITestSetup.find("sc_del2", on: app.db))
            setup.manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"script":"test_rm.py","tier":"public","order":1,"dependsOn":[],"points":1}],"timeLimitSeconds":10,"makefile":null}
                """
            try await setup.save(on: app.db)

            let a = try await insertAssignment(testSetupID: "sc_del2", title: "DeleteManifest")
            let id = a.publicID

            try await app.asyncTest(
                .DELETE, "/instructor/\(id)/scripts/test_rm.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            let updated = try #require(try await APITestSetup.find("sc_del2", on: app.db))
            #expect(
                updated.manifest.contains("test_rm.py") == false,
                "Manifest should no longer contain deleted script, got: \(updated.manifest)")

        }
    }

    @Test func deleteScriptReturns409WhenDependentsExist() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(
                id: "sc_del3",
                withEntries: [
                    ("test_a.py", "pass\n"),
                    ("test_b.py", "pass\n"),
                ])

            // test_b depends on test_a.
            let setup = try #require(try await APITestSetup.find("sc_del3", on: app.db))
            setup.manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[
                  {"script":"test_a.py","tier":"public","order":1,"dependsOn":[],"points":1},
                  {"script":"test_b.py","tier":"public","order":2,"dependsOn":["test_a.py"],"points":1}
                ],"timeLimitSeconds":10,"makefile":null}
                """
            try await setup.save(on: app.db)

            let a = try await insertAssignment(testSetupID: "sc_del3", title: "DeleteConflict")
            let id = a.publicID

            try await app.asyncTest(
                .DELETE, "/instructor/\(id)/scripts/test_a.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .conflict)
                }
            )

        }
    }

    @Test func deleteScriptReturns404ForMissingFile() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "sc_del4", withEntries: [("test_a.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_del4", title: "DeleteMissing")
            let id = a.publicID

            try await app.asyncTest(
                .DELETE, "/instructor/\(id)/scripts/nonexistent.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                }
            )

        }
    }

    @Test func deleteScriptReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            guard FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
                FileManager.default.fileExists(atPath: "/usr/bin/zip")
            else {
                throw XCTSkip("zip/unzip not available")
            }
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "sc_del5", withEntries: [("test_a.py", "pass\n")])
            let a = try await insertAssignment(testSetupID: "sc_del5", title: "DeleteStudent")
            let id = a.publicID

            try await app.asyncTest(
                .DELETE, "/instructor/\(id)/scripts/test_a.py",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }
}
