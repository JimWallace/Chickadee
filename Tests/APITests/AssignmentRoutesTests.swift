// Tests/APITests/AssignmentRoutesTests.swift
//
// Integration tests for Phase 7 instructor assignment management routes.
//
//   GET  /assignments
//   POST /assignments                       (publish → draft)
//   GET  /assignments/:id/validate
//   POST /assignments/:id/open
//   POST /assignments/:id/close
//   POST /assignments/:id/delete

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class AssignmentRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-art-\(UUID().uuidString)/")
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
        let user = APIUser(username: "testinstructor", passwordHash: hash, role: "instructor")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "testinstructor", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    private func loginAsStudent() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "teststudent", passwordHash: hash, role: "student")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "teststudent", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    // MARK: - Setup helper

    @discardableResult
    private func insertSetup(id: String) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: tmpDir + "testsetups/\(id).zip")
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String, isOpen: Bool) async throws -> APIAssignment {
        let a = APIAssignment(testSetupID: testSetupID, title: title, dueAt: nil, isOpen: isOpen)
        try await a.save(on: app.db)
        return a
    }

    // MARK: - GET /assignments

    func testStudentCannotAccessAssignments() async throws {
        let cookie = try await loginAsStudent()
        try await app.test(.GET, "/assignments", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testInstructorCanAccessAssignments() async throws {
        let cookie = try await loginAsInstructor()
        try await app.test(.GET, "/assignments", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            // 500 expected because Leaf is not configured in tests — but middleware passed (not 401/403).
            XCTAssertNotEqual(res.status, .unauthorized)
            XCTAssertNotEqual(res.status, .forbidden)
        })
    }

    // MARK: - POST /assignments (publish → creates draft)

    func testPublishCreatesDraftAssignment() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_pub1")

        try await app.test(.POST, "/assignments", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
            try req.content.encode(
                ["testSetupID": "setup_pub1", "title": "Lab 1"],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Redirects to /assignments/:id/validate
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("/assignments/") && location.contains("/validate"),
                          "Expected redirect to /assignments/:id/validate, got \(location)")
        })

        // Assignment should be in DB as draft (isOpen: false)
        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$testSetupID == "setup_pub1")
            .first()
        XCTAssertNotNil(assignment)
        XCTAssertEqual(assignment?.title, "Lab 1")
        XCTAssertEqual(assignment?.isOpen, false)
    }

    func testPublishUnknownSetupReturnsBadRequest() async throws {
        let cookie = try await loginAsInstructor()

        try await app.test(.POST, "/assignments", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
            try req.content.encode(
                ["testSetupID": "does_not_exist", "title": "Oops"],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testPublishDuplicateSetupRedirects() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_dup")
        try await insertAssignment(testSetupID: "setup_dup", title: "Already Published", isOpen: false)

        try await app.test(.POST, "/assignments", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
            try req.content.encode(
                ["testSetupID": "setup_dup", "title": "Duplicate"],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Should redirect to /assignments without creating a second record
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/assignments")
        })

        let count = try await APIAssignment.query(on: app.db)
            .filter(\.$testSetupID == "setup_dup")
            .count()
        XCTAssertEqual(count, 1)
    }

    // MARK: - POST /assignments/:id/open

    func testOpenAssignmentSetsIsOpenTrue() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_open")
        let a = try await insertAssignment(testSetupID: "setup_open", title: "Draft", isOpen: false)
        let id = try XCTUnwrap(a.id?.uuidString)

        try await app.test(.POST, "/assignments/\(id)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/assignments")
        })

        let updated = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertEqual(updated?.isOpen, true)
    }

    // MARK: - POST /assignments/:id/close

    func testCloseAssignmentSetsIsOpenFalse() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_close")
        let a = try await insertAssignment(testSetupID: "setup_close", title: "Open", isOpen: true)
        let id = try XCTUnwrap(a.id?.uuidString)

        try await app.test(.POST, "/assignments/\(id)/close", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertEqual(updated?.isOpen, false)
    }

    // MARK: - POST /assignments/:id/delete

    func testDeleteAssignmentRemovesRecord() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_del")
        let a = try await insertAssignment(testSetupID: "setup_del", title: "To Remove", isOpen: false)
        let id = try XCTUnwrap(a.id?.uuidString)

        try await app.test(.POST, "/assignments/\(id)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let gone = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertNil(gone)
    }

    func testDeleteNonexistentAssignmentReturnsNotFound() async throws {
        let cookie = try await loginAsInstructor()
        let fakeID = UUID().uuidString

        try await app.test(.POST, "/assignments/\(fakeID)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /assignments/:id/open — nonexistent

    func testOpenNonexistentAssignmentReturnsNotFound() async throws {
        let cookie = try await loginAsInstructor()
        let fakeID = UUID().uuidString

        try await app.test(.POST, "/assignments/\(fakeID)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }
}
