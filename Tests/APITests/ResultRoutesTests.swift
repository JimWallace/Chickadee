import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
@testable import Core
import Foundation

final class ResultRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpResultsDir: String!
    private let workerSecret = "test-worker-secret"

    override func setUp() async throws {
        app = try await Application.make(.testing)

        // Use a temp directory so tests don't pollute the project directory
        tmpResultsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-test-results-\(UUID().uuidString)", isDirectory: true)
            .path + "/"
        try FileManager.default.createDirectory(
            atPath: tmpResultsDir,
            withIntermediateDirectories: true
        )

        app.resultsDirectory = tmpResultsDir
        app.routes.defaultMaxBodySize = "10mb"

        // Sessions are required because routes.swift now registers UserSessionAuthenticator.
        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)

        try await configureTestDatabase(app)

        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpResultsDir)
    }

    // MARK: - Helpers

    private func makeCollection(
        submissionID: String = "sub_test",
        buildStatus: BuildStatus = .passed,
        outcomes: [TestOutcome] = []
    ) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: buildStatus,
            compilerOutput: buildStatus == .failed ? "error: ';' expected" : nil,
            outcomes: outcomes,
            totalTests: outcomes.count,
            passCount: outcomes.filter { $0.status == .pass }.count,
            failCount: outcomes.filter { $0.status == .fail }.count,
            errorCount: outcomes.filter { $0.status == .error }.count,
            timeoutCount: outcomes.filter { $0.status == .timeout }.count,
            executionTimeMs: 100,
            runnerVersion: "java-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private func bodyData(for collection: TestOutcomeCollection) throws -> ByteBuffer {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(collection)
        return ByteBuffer(data: data)
    }

    private func ensureSubmissionExists(
        submissionID: String,
        testSetupID: String = "setup_001"
    ) throws {
        if try APITestSetup.find(testSetupID, on: app.db).wait() == nil {
            let course = APICourse(code: "TEST101", name: "Test Course")
            try course.save(on: app.db).wait()
            let courseID = try course.requireID()
            let setup = APITestSetup(
                id: testSetupID,
                manifest: #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: tmpResultsDir + "\(testSetupID).zip",
                courseID: courseID
            )
            try setup.save(on: app.db).wait()
        }

        if try APISubmission.find(submissionID, on: app.db).wait() == nil {
            let submission = APISubmission(
                id: submissionID,
                testSetupID: testSetupID,
                zipPath: tmpResultsDir + "\(submissionID).zip",
                attemptNumber: 1,
                status: "pending",
                kind: APISubmission.Kind.student
            )
            try submission.save(on: app.db).wait()
        }
    }

    // MARK: - Tests

    private let resultsPath = "/api/v1/worker/results"

    func testReportResultsReturnsReceived() throws {
        let collection = makeCollection()
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        try app.test(.POST, resultsPath, beforeRequest: { req in
            req.headers = workerHMACHeaders(method: .POST, path: self.resultsPath,
                                            body: body, workerSecret: self.workerSecret)
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let response = try res.content.decode(ReportResponse.self)
            XCTAssertTrue(response.received)
        })
    }

    func testReportResultsWritesFileToDisk() throws {
        let collection = makeCollection(submissionID: "sub_disktest")
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        try app.test(.POST, resultsPath, beforeRequest: { req in
            req.headers = workerHMACHeaders(method: .POST, path: self.resultsPath,
                                            body: body, workerSecret: self.workerSecret)
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpResultsDir)
        let resultFile = files.first { $0.hasPrefix("sub_disktest") }
        XCTAssertNotNil(resultFile, "Expected a result file for sub_disktest to be written")
    }

    func testReportResultsWithFailedBuild() throws {
        let collection = makeCollection(buildStatus: .failed, outcomes: [])
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        try app.test(.POST, resultsPath, beforeRequest: { req in
            req.headers = workerHMACHeaders(method: .POST, path: self.resultsPath,
                                            body: body, workerSecret: self.workerSecret)
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let response = try res.content.decode(ReportResponse.self)
            XCTAssertTrue(response.received)
        })
    }

    func testReportResultsRejectsMalformedJSON() throws {
        let badBody = ByteBuffer(string: "not valid json")
        try app.test(.POST, resultsPath, beforeRequest: { req in
            req.headers = workerHMACHeaders(method: .POST, path: self.resultsPath,
                                            body: badBody, workerSecret: self.workerSecret)
            req.body = badBody
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unprocessableEntity)
        })
    }

    func testReportResultsRejectsEmptyBody() throws {
        try app.test(.POST, resultsPath, beforeRequest: { req in
            req.headers = workerHMACHeaders(method: .POST, path: self.resultsPath,
                                            workerSecret: self.workerSecret)
        }, afterResponse: { res in
            // Either 400 or 422 is acceptable for empty body
            XCTAssertTrue(
                res.status == .badRequest || res.status == .unprocessableEntity,
                "Expected 400 or 422, got \(res.status)"
            )
        })
    }

    func testReportResultsAcceptsLargeSignedBodyOverRealHTTP() async throws {
        let largeMessage = String(repeating: "abcdefghijklmnopqrstuvwxyz0123456789", count: 4096)
        let outcome = TestOutcome(
            testName: "large_payload_test",
            testClass: nil,
            tier: .pub,
            status: .fail,
            shortResult: largeMessage,
            longResult: largeMessage,
            executionTimeMs: 100,
            memoryUsageBytes: nil,
            attemptNumber: 1,
            isFirstPassSuccess: false
        )
        let collection = makeCollection(
            submissionID: "sub_large_http",
            buildStatus: .failed,
            outcomes: [outcome]
        )
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        try await app.testable(method: .running(hostname: "localhost", port: 0)).test(
            .POST,
            self.resultsPath,
            headers: workerHMACHeaders(
                method: .POST,
                path: self.resultsPath,
                body: body,
                workerSecret: self.workerSecret
            ),
            body: body
        ) { res async in
            XCTAssertEqual(res.status, .ok)
            do {
                let response = try res.content.decode(ReportResponse.self)
                XCTAssertTrue(response.received)
            } catch {
                XCTFail("Failed to decode ReportResponse: \(error)")
            }
        }
    }
}
