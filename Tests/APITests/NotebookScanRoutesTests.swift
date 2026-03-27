// Tests/APITests/NotebookScanRoutesTests.swift
//
// Integration tests for:
//   POST /instructor/scan-notebook

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class NotebookScanRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-nbscan-\(UUID().uuidString)/")
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
        return try await loginUser(username: "testinstructor_nbscan", password: "testpassword",
                                   role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "teststudent_nbscan", password: "testpassword",
                                   role: "student", on: app)
    }

    // MARK: - Sample notebook fixtures

    private let notebookWithTwoFunctions = """
    {
      "cells": [
        {
          "cell_type": "code",
          "metadata": {},
          "source": "def add(a, b):\\n    return a + b\\n\\ndef multiply(x, y):\\n    return x * y\\n"
        }
      ],
      "metadata": {},
      "nbformat": 4,
      "nbformat_minor": 5
    }
    """

    private let notebookWithNoFunctions = """
    {
      "cells": [
        {
          "cell_type": "code",
          "metadata": {},
          "source": "x = 1\\ny = 2\\nprint(x + y)\\n"
        }
      ],
      "metadata": {},
      "nbformat": 4,
      "nbformat_minor": 5
    }
    """

    private let notebookWithTypeHints = """
    {
      "cells": [
        {
          "cell_type": "code",
          "metadata": {},
          "source": "def greet(name: str) -> str:\\n    return 'Hello ' + name\\n"
        }
      ],
      "metadata": {},
      "nbformat": 4,
      "nbformat_minor": 5
    }
    """

    // MARK: - POST /instructor/scan-notebook

    func testScanNotebookReturnsFunctionsForInstructor() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithTwoFunctions)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("\"add\""),
                              "Expected function 'add' in response, got: \(body.prefix(500))")
                XCTAssertTrue(body.contains("\"multiply\""),
                              "Expected function 'multiply' in response, got: \(body.prefix(500))")
            }
        )
    }

    func testScanNotebookReturnsEmptyArrayForNoFunctions() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithNoFunctions)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string.trimmingCharacters(in: .whitespacesAndNewlines), "[]",
                               "Expected empty array for notebook with no functions")
            }
        )
    }

    func testScanNotebookIncludesParamNames() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithTwoFunctions)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("\"a\"") && body.contains("\"b\""),
                              "Expected param names 'a', 'b' in response, got: \(body.prefix(500))")
                XCTAssertTrue(body.contains("\"paramCount\""),
                              "Expected 'paramCount' field in response")
            }
        )
    }

    func testScanNotebookIncludesTemplates() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithTwoFunctions)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("\"templates\""),
                              "Expected 'templates' array in response, got: \(body.prefix(500))")
                XCTAssertTrue(body.contains("\"exists\"") || body.contains("Exists"),
                              "Expected exists template in response")
            }
        )
    }

    func testScanNotebookReturnsTypeHintFlag() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithTypeHints)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("\"hasTypeHints\":true") || body.contains("\"hasTypeHints\" : true"),
                              "Expected hasTypeHints true for typed function, got: \(body.prefix(500))")
            }
        )
    }

    func testScanNotebookReturns403ForStudent() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithTwoFunctions)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        )
    }

    func testScanNotebookReturns400ForEmptyBody() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                // No body
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .badRequest)
            }
        )
    }

    func testScanNotebookIgnoresPrivateFunctions() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        let notebookWithPrivate = """
        {
          "cells": [
            {
              "cell_type": "code",
              "metadata": {},
              "source": "def _helper(x):\\n    pass\\ndef public_fn(x):\\n    pass\\n"
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """

        try await app.asyncTest(.POST, "/instructor/scan-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: notebookWithPrivate)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("\"public_fn\""),
                              "Expected public_fn in response, got: \(body.prefix(500))")
                XCTAssertFalse(body.contains("\"_helper\""),
                               "Private function should be excluded, got: \(body.prefix(500))")
            }
        )
    }
}
