// Tests/APITests/WorkerRoutesTests.swift
//
// Integration tests for WorkerJobRoutes and WorkerArtifactRoutes:
//   POST /api/v1/worker/request                           — claim next pending job
//   GET  /api/v1/worker/submissions/:id/download          — stream submission zip
//   GET  /api/v1/worker/testsetups/:id/download           — stream test-setup zip

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation
import Core

final class WorkerRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: URL!
    private let workerSecret = "test-worker-secret-abc123"

    // Minimal worker-mode manifest JSON (gradingMode defaults to .worker)
    private let workerManifestJSON = """
    {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
    """

    // Browser-mode manifest JSON
    private let browserManifestJSON = """
    {"schemaVersion":1,"gradingMode":"browser","testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
    """

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-worker-\(UUID().uuidString)")
        let dirs = ["results", "testsetups", "submissions"].map { tmpDir.appendingPathComponent($0) }
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = dirs[0].path + "/"
        app.testSetupsDirectory  = dirs[1].path + "/"
        app.submissionsDirectory = dirs[2].path + "/"

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
        try await app.autoMigrate().get()
        configureLeaf(app)
        try routes(app)

        // Inject the worker secret so requireWorkerSecret passes
        await app.workerSecretStore.setRuntimeOverride(workerSecret)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func workerHeaders() -> HTTPHeaders {
        var h = HTTPHeaders()
        h.add(name: "X-Worker-Secret", value: workerSecret)
        h.contentType = .json
        return h
    }

    private func makeDummyZip(named filename: String, in dir: URL) throws -> String {
        let data = Data("PK\0\0".utf8) // minimal fake zip content
        let path = dir.appendingPathComponent(filename).path
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeTestSetup(id: String, manifest: String) async throws -> APITestSetup {
        let zipPath = try makeDummyZip(named: "\(id).zip",
                                       in: tmpDir.appendingPathComponent("testsetups"))
        // Each test setup needs a course (FK constraint); create a throw-away one.
        let course = APICourse(code: "WK_\(id)", name: "Worker Test Course", openEnrollment: false)
        try await course.save(on: app.db)
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath,
                                 courseID: try course.requireID())
        try await setup.save(on: app.db)
        return setup
    }

    private func makeSubmission(id: String, setupID: String, status: String = "pending",
                                 kind: String = APISubmission.Kind.student) async throws -> APISubmission {
        let zipPath = try makeDummyZip(named: "\(id).zip",
                                       in: tmpDir.appendingPathComponent("submissions"))
        let sub = APISubmission(id: id, testSetupID: setupID, zipPath: zipPath,
                                attemptNumber: 1, status: status,
                                filename: "submission.zip", userID: nil, kind: kind)
        try await sub.save(on: app.db)
        return sub
    }

    // MARK: - Auth tests

    func testRequestJob_missingSecret_returns401() async throws {
        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = .init(string: #"{"workerID":"w1"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRequestJob_wrongSecret_returns401() async throws {
        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers.add(name: "X-Worker-Secret", value: "wrong-secret")
            req.headers.contentType = .json
            req.body = .init(string: #"{"workerID":"w1"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testDownloadSubmission_missingSecret_returns401() async throws {
        try await app.test(.GET, "/api/v1/worker/submissions/sub1/download") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testDownloadTestSetup_missingSecret_returns401() async throws {
        try await app.test(.GET, "/api/v1/worker/testsetups/setup1/download") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: - POST /api/v1/worker/request

    func testRequestJob_noPendingJobs_returns204() async throws {
        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers = workerHeaders()
            req.body = .init(string: #"{"workerID":"w1"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    func testRequestJob_pendingWorkerModeStudent_returnsJob() async throws {
        let setup = try await makeTestSetup(id: "wsetup_01", manifest: workerManifestJSON)
        let sub   = try await makeSubmission(id: "wsub_01", setupID: setup.id!)

        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers = workerHeaders()
            req.body = .init(string: #"{"workerID":"w1"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(Job.self)
            XCTAssertEqual(job.submissionID, sub.id)
            XCTAssertEqual(job.testSetupID, setup.id)
            XCTAssertEqual(job.attemptNumber, 1)
        })

        // Submission should now be "assigned"
        let updated = try await APISubmission.find(sub.id, on: app.db)
        XCTAssertEqual(updated?.status, "assigned")
        XCTAssertEqual(updated?.workerID, "w1")
    }

    func testRequestJob_browserModeStudent_ignored_returns204() async throws {
        // Browser-mode student submissions should NOT be claimed by the worker runner
        let setup = try await makeTestSetup(id: "bsetup_01", manifest: browserManifestJSON)
        _ = try await makeSubmission(id: "bsub_01", setupID: setup.id!, kind: APISubmission.Kind.student)

        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers = workerHeaders()
            req.body = .init(string: #"{"workerID":"w1"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    func testRequestJob_pendingValidation_returnsJob() async throws {
        // Validation submissions are always worker-mode regardless of manifest gradingMode
        let setup = try await makeTestSetup(id: "vsetup_01", manifest: workerManifestJSON)
        let sub   = try await makeSubmission(id: "vsub_01", setupID: setup.id!,
                                              kind: APISubmission.Kind.validation)

        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers = workerHeaders()
            req.body = .init(string: #"{"workerID":"w2"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(Job.self)
            XCTAssertEqual(job.submissionID, sub.id)
        })
    }

    func testRequestJob_studentPreferredOverValidation() async throws {
        // Worker-mode student submission should be returned before a validation submission
        let setup  = try await makeTestSetup(id: "psetup_01", manifest: workerManifestJSON)
        let student = try await makeSubmission(id: "psub_student", setupID: setup.id!,
                                               kind: APISubmission.Kind.student)
        _ = try await makeSubmission(id: "psub_val", setupID: setup.id!,
                                     kind: APISubmission.Kind.validation)

        try await app.test(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers = workerHeaders()
            req.body = .init(string: #"{"workerID":"w3"}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(Job.self)
            XCTAssertEqual(job.submissionID, student.id,
                           "Student submission should be preferred over validation")
        })
    }

    // MARK: - GET /api/v1/worker/submissions/:id/download

    func testDownloadSubmission_existingFile_returns200() async throws {
        let setup = try await makeTestSetup(id: "dlsetup_01", manifest: workerManifestJSON)
        let sub   = try await makeSubmission(id: "dlsub_01", setupID: setup.id!)

        try await app.test(.GET, "/api/v1/worker/submissions/\(sub.id!)/download",
        beforeRequest: { req in
            req.headers.add(name: "X-Worker-Secret", value: workerSecret)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testDownloadSubmission_notFound_returns404() async throws {
        try await app.test(.GET, "/api/v1/worker/submissions/nonexistent/download",
        beforeRequest: { req in
            req.headers.add(name: "X-Worker-Secret", value: workerSecret)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - GET /api/v1/worker/testsetups/:id/download

    func testDownloadTestSetup_existingFile_returns200() async throws {
        let setup = try await makeTestSetup(id: "dlts_01", manifest: workerManifestJSON)

        try await app.test(.GET, "/api/v1/worker/testsetups/\(setup.id!)/download",
        beforeRequest: { req in
            req.headers.add(name: "X-Worker-Secret", value: workerSecret)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testDownloadTestSetup_notFound_returns404() async throws {
        try await app.test(.GET, "/api/v1/worker/testsetups/nonexistent/download",
        beforeRequest: { req in
            req.headers.add(name: "X-Worker-Secret", value: workerSecret)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }
}
