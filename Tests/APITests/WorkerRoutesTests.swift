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
        app = try await Application.make(.testing)

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
        app.migrations.add(AddCourseEnrollmentMode())
        app.migrations.add(CreateSubmissionDiagnostics())
        app.migrations.add(CreateRequestMetrics())
        app.migrations.add(CreateJobExecutionMetrics())
        app.migrations.add(CreateRunnerSnapshots())
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        configureLeaf(app)
        try routes(app)

        // Initialize the claim queue before requests start (mirrors configure() eager-init pattern).
        app.storage[WorkerClaimQueueKey.self] = WorkerClaimQueue()
        // Set the shared secret so WorkerHMACAuthMiddleware validates signed requests
        await app.workerSecretStore.setRuntimeOverride(workerSecret)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func workerHeaders(method: HTTPMethod = .POST, path: String, body: ByteBuffer? = nil) -> HTTPHeaders {
        workerHMACHeaders(method: method, path: path, body: body, workerSecret: workerSecret)
    }

    private func workerRequestBody(
        workerID: String,
        hostname: String? = nil,
        runnerVersion: String = "runner-tests/1.0",
        maxConcurrentJobs: Int = 1,
        activeJobs: Int = 0,
        profile: RunnerCapabilityProfile? = nil
    ) throws -> ByteBuffer {
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: hostname ?? "\(workerID).local",
            runnerVersion: runnerVersion,
            maxConcurrentJobs: maxConcurrentJobs,
            activeJobs: activeJobs,
            profile: profile
        )
        return ByteBuffer(data: try JSONEncoder().encode(payload))
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
        let course = APICourse(code: "WK_\(id)", name: "Worker Test Course", enrollmentMode: .closed)
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

    private func makeAssignment(setupID: String, title: String = "Assignment") async throws -> APIAssignment {
        guard let courseID = try await APITestSetup.find(setupID, on: app.db)?.courseID else {
            throw XCTSkip("setup missing course")
        }
        let assignment = APIAssignment(testSetupID: setupID, title: title, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    private func addRequirement(
        assignmentID: UUID,
        spec: AssignmentRequirementSpec
    ) async throws {
        let requirement = AssignmentRequirement(assignmentID: assignmentID, specification: spec)
        try await requirement.save(on: app.db)
    }

    // MARK: - Auth tests

    func testRequestJob_missingSecret_returns401() async throws {
        try await app.asyncTest(.POST, "/api/v1/worker/request", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = try self.workerRequestBody(workerID: "w1")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRequestJob_wrongSecret_returns401() async throws {
        // Sending a bad/absent signature should still yield 401
        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: "w1")
        var badHeaders = workerHMACHeaders(method: .POST, path: path, body: body,
                                           workerSecret: "wrong-secret")
        badHeaders.contentType = .json
        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = badHeaders
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testDownloadSubmission_missingSecret_returns401() async throws {
        try await app.asyncTest(.GET, "/api/v1/worker/submissions/sub1/download") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testDownloadTestSetup_missingSecret_returns401() async throws {
        try await app.asyncTest(.GET, "/api/v1/worker/testsetups/setup1/download") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: - POST /api/v1/worker/request

    func testRequestJob_noPendingJobs_returns204() async throws {
        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: "w1")
        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .POST, path: path, body: body)
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    func testRequestJob_pendingWorkerModeStudent_returnsJob() async throws {
        let setup = try await makeTestSetup(id: "wsetup_01", manifest: workerManifestJSON)
        let sub   = try await makeSubmission(id: "wsub_01", setupID: setup.id!)

        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: "w1")
        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .POST, path: path, body: body)
            req.body = body
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

        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: "w1")
        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .POST, path: path, body: body)
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    func testRequestJob_pendingValidation_returnsJob() async throws {
        // Validation submissions are always worker-mode regardless of manifest gradingMode
        let setup = try await makeTestSetup(id: "vsetup_01", manifest: workerManifestJSON)
        let sub   = try await makeSubmission(id: "vsub_01", setupID: setup.id!,
                                              kind: APISubmission.Kind.validation)

        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: "w2")
        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .POST, path: path, body: body)
            req.body = body
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

        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: "w3")
        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .POST, path: path, body: body)
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(Job.self)
            XCTAssertEqual(job.submissionID, student.id,
                           "Student submission should be preferred over validation")
        })
    }

    func testRequestJob_concurrentClaims_onlyOneSucceeds() async throws {
        // One pending submission; two workers race to claim it.
        // The transaction in requestJob must ensure only one succeeds.
        let setup = try await makeTestSetup(id: "cc_setup", manifest: workerManifestJSON)
        _ = try await makeSubmission(id: "cc_sub", setupID: setup.id!)

        let path    = "/api/v1/worker/request"
        let secret  = workerSecret      // String — Sendable
        let testApp = app!              // Application — @unchecked Sendable

        var responses: [XCTHTTPResponse] = []
        try await withThrowingTaskGroup(of: XCTHTTPResponse.self) { group in
            for workerID in ["w1", "w2"] {
                // Compute per-worker values outside the task so the closure
                // captures only Sendable types and avoids capturing `self`.
                let body = try self.workerRequestBody(workerID: workerID)
                let headers = workerHMACHeaders(method: .POST, path: path,
                                                body: body, workerSecret: secret)
                group.addTask {
                    return try await testApp.asyncSendRequest(.POST, path) { req in
                        req.headers = headers
                        req.body    = body
                    }
                }
            }
            for try await response in group {
                responses.append(response)
            }
        }

        XCTAssertEqual(responses.count, 2)
        let statuses = responses.map(\.status)
        XCTAssertTrue(statuses.contains(.ok),        "One worker must claim the job")
        XCTAssertTrue(statuses.contains(.noContent), "The other worker must find nothing")

        // The submission must be owned by exactly one worker.
        let updated = try await APISubmission.find("cc_sub", on: app.db)
        XCTAssertEqual(updated?.status, "assigned")
        XCTAssertNotNil(updated?.workerID)
    }

    // MARK: - GET /api/v1/worker/submissions/:id/download

    func testDownloadSubmission_existingFile_returns200() async throws {
        let setup = try await makeTestSetup(id: "dlsetup_01", manifest: workerManifestJSON)
        let sub   = try await makeSubmission(id: "dlsub_01", setupID: setup.id!)

        let path = "/api/v1/worker/submissions/\(sub.id!)/download"
        try await app.asyncTest(.GET, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .GET, path: path)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testDownloadSubmission_notFound_returns404() async throws {
        let path = "/api/v1/worker/submissions/nonexistent/download"
        try await app.asyncTest(.GET, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .GET, path: path)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - GET /api/v1/worker/testsetups/:id/download

    func testDownloadTestSetup_existingFile_returns200() async throws {
        let setup = try await makeTestSetup(id: "dlts_01", manifest: workerManifestJSON)

        let path = "/api/v1/worker/testsetups/\(setup.id!)/download"
        try await app.asyncTest(.GET, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .GET, path: path)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testDownloadTestSetup_notFound_returns404() async throws {
        let path = "/api/v1/worker/testsetups/nonexistent/download"
        try await app.asyncTest(.GET, path, beforeRequest: { req in
            req.headers = workerHeaders(method: .GET, path: path)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }
}
