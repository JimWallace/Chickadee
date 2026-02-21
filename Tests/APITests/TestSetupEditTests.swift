// Tests/APITests/TestSetupEditTests.swift
//
// Integration tests for Phase 8 notebook editor endpoints.
//
//   PUT  /api/v1/testsetups/:id/assignment  — save edited notebook
//   GET  /api/v1/testsetups/:id/assignment  — serves flat file when present
//   GET  /assignments/:id/edit              — instructor-only editor page

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class TestSetupEditTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-edit-\(UUID().uuidString)/")
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
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(AddAttemptNumberToSubmissions())
        app.migrations.add(AddFilenameToSubmissions())
        app.migrations.add(AddSourceToResults())
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateAssignments())
        app.migrations.add(AddUserIDToSubmissions())
        app.migrations.add(AddNotebookPathToTestSetups())
        try await app.autoMigrate().get()

        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "testinstructor_edit", passwordHash: hash, role: "instructor")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "testinstructor_edit", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    private func loginAsStudent() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "teststudent_edit", passwordHash: hash, role: "student")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "teststudent_edit", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    // MARK: - Setup helpers

    /// Creates a test setup record in the DB (no real zip on disk).
    @discardableResult
    private func insertSetup(id: String) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(
            id: id,
            manifest: manifest,
            zipPath: tmpDir + "testsetups/\(id).zip"
        )
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String) async throws -> APIAssignment {
        let a = APIAssignment(testSetupID: testSetupID, title: title, dueAt: nil, isOpen: true)
        try await a.save(on: app.db)
        return a
    }

    // A minimal valid notebook JSON to use as test data.
    private let sampleNotebookJSON = """
    {
        "nbformat": 4,
        "nbformat_minor": 5,
        "metadata": {},
        "cells": [
            {
                "cell_type": "code",
                "source": ["# TEST: sample tier=public\\nassert 1 == 1"],
                "metadata": {},
                "outputs": []
            }
        ]
    }
    """

    // MARK: - PUT /api/v1/testsetups/:id/assignment

    func testPutAssignmentSavesFileToDisk() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_put1")

        try await app.test(.PUT, "/api/v1/testsetups/setup_put1/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: sampleNotebookJSON)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .noContent)
            }
        )

        // File should be on disk.
        let expectedPath = tmpDir + "testsetups/setup_put1.ipynb"
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath),
                      "Expected flat .ipynb file at \(expectedPath)")
    }

    func testPutAssignmentUpdatesNotebookPathInDB() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_put2")

        try await app.test(.PUT, "/api/v1/testsetups/setup_put2/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: sampleNotebookJSON)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .noContent)
            }
        )

        let updated = try await APITestSetup.find("setup_put2", on: app.db)
        XCTAssertNotNil(updated?.notebookPath, "notebookPath should be set after PUT")
        XCTAssertTrue(updated?.notebookPath?.hasSuffix("setup_put2.ipynb") == true)
    }

    func testGetAssignmentServesFlatFileWhenPresent() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_flat")

        // Write a flat notebook file directly.
        let flatPath = tmpDir + "testsetups/setup_flat.ipynb"
        let editedJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["# edited"],"metadata":{},"outputs":[]}]}
        """
        try editedJSON.write(toFile: flatPath, atomically: true, encoding: .utf8)

        // Update DB record to point at the flat file.
        let setup = try await APITestSetup.find("setup_flat", on: app.db)!
        setup.notebookPath = flatPath
        try await setup.save(on: app.db)

        // GET should return the flat file's content.
        try await app.test(.GET, "/api/v1/testsetups/setup_flat/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("# edited"),
                              "Expected flat file content, got: \(body.prefix(200))")
            }
        )
    }

    func testPutAssignmentRejectsNonJSON() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_bad")

        try await app.test(.PUT, "/api/v1/testsetups/setup_bad/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: "this is not JSON!!!")
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .unprocessableEntity)
            }
        )
    }

    func testPutAssignmentReturnsNotFoundForUnknownSetup() async throws {
        let cookie = try await loginAsInstructor()

        try await app.test(.PUT, "/api/v1/testsetups/does_not_exist/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: sampleNotebookJSON)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    // MARK: - Role guard on PUT

    func testStudentCannotPutAssignment() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "setup_student_put")

        // Students are not on the instructor route group — middleware rejects them.
        try await app.test(.PUT, "/api/v1/testsetups/setup_student_put/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: sampleNotebookJSON)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }

    // MARK: - GET /assignments/:id/edit

    func testEditPageRequiresInstructor() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "setup_ep1")
        let a = try await insertAssignment(testSetupID: "setup_ep1", title: "Lab")
        let id = try XCTUnwrap(a.id?.uuidString)

        try await app.test(.GET, "/assignments/\(id)/edit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }

    func testEditPageNotFoundForUnknownAssignment() async throws {
        let cookie = try await loginAsInstructor()
        let fakeID = UUID().uuidString

        try await app.test(.GET, "/assignments/\(fakeID)/edit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    func testEditPageInstructorAccessGranted() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_ep2")
        let a = try await insertAssignment(testSetupID: "setup_ep2", title: "My Lab")
        let id = try XCTUnwrap(a.id?.uuidString)

        try await app.test(.GET, "/assignments/\(id)/edit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                // 500 is expected — Leaf not configured in tests — but middleware passed.
                XCTAssertNotEqual(res.status, .unauthorized)
                XCTAssertNotEqual(res.status, .forbidden)
                XCTAssertNotEqual(res.status, .notFound)
            }
        )
    }
}
