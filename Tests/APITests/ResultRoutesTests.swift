import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import Core
@testable import chickadee_server

final class ResultRoutesTests: XCTestCase {

    private var app: Application!
    private let workerSecret = "test-worker-secret"

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-test-results")
        app.routes.defaultMaxBodySize = "10mb"
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
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

    private func bodyData(for report: WorkerExecutionReport) throws -> ByteBuffer {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
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
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: app.resultsDirectory + "\(testSetupID).zip",
                courseID: courseID
            )
            try setup.save(on: app.db).wait()
        }

        if try APISubmission.find(submissionID, on: app.db).wait() == nil {
            let submission = APISubmission(
                id: submissionID,
                testSetupID: testSetupID,
                zipPath: app.resultsDirectory + "\(submissionID).zip",
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

        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(ReportResponse.self)
                XCTAssertTrue(response.received)
            })
    }

    func testReportResultsWritesFileToDisk() throws {
        let collection = makeCollection(submissionID: "sub_disktest")
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
            })

        let files = try FileManager.default.contentsOfDirectory(atPath: app.resultsDirectory)
        let resultFile = files.first { $0.hasPrefix("sub_disktest") }
        XCTAssertNotNil(resultFile, "Expected a result file for sub_disktest to be written")
    }

    func testReportResultsAcceptsWrappedExecutionReportPayload() async throws {
        let collection = makeCollection(submissionID: "sub_wrapped_report")
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let report = WorkerExecutionReport(
            collection: collection,
            diagnostics: WorkerExecutionDiagnostics(
                runnerID: "runner-stage",
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101),
                finalStatus: "passed",
                timedOut: false,
                exitCode: 0,
                terminationReason: nil,
                peakRSSBytes: nil,
                wallClockMs: 100,
                childProcessCount: nil,
                stdoutBytes: nil,
                stderrBytes: nil,
                stageTimings: WorkerExecutionStageTimings(
                    workdirSetupMs: 12,
                    submissionDownloadMs: 45,
                    testSetupAcquireMs: 67,
                    submissionPrepareMs: 89,
                    testExecutionMs: 100
                )
            )
        )
        let body = try bodyData(for: report)

        try await app.asyncTest(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
            })

        let files = try FileManager.default.contentsOfDirectory(atPath: app.resultsDirectory)
        let resultFile = files.first { $0.hasPrefix(collection.submissionID) }
        XCTAssertNotNil(resultFile, "Expected a result file for wrapped reports to be written")
    }

    func testReportResultsWithFailedBuild() throws {
        let collection = makeCollection(buildStatus: .failed, outcomes: [])
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(ReportResponse.self)
                XCTAssertTrue(response.received)
            })
    }

    func testReportResultsRejectsMalformedJSON() throws {
        let badBody = ByteBuffer(string: "not valid json")
        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: badBody, workerSecret: self.workerSecret)
                req.body = badBody
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .unprocessableEntity)
            })
    }

    func testReportResultsRejectsEmptyBody() throws {
        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    workerSecret: self.workerSecret)
            },
            afterResponse: { res in
                // Either 400 or 422 is acceptable for empty body
                XCTAssertTrue(
                    res.status == .badRequest || res.status == .unprocessableEntity,
                    "Expected 400 or 422, got \(res.status)"
                )
            })
    }

    func testDuplicateResultSubmissionIsIdempotent() throws {
        // Simulates a worker retry: the same TestOutcomeCollection is submitted
        // twice (e.g. the first POST timed out from the worker's perspective but
        // actually succeeded on the server). The second POST must succeed and must
        // not corrupt the submission's state.
        let collection = makeCollection(submissionID: "sub_dup_result")
        try ensureSubmissionExists(submissionID: collection.submissionID, testSetupID: collection.testSetupID)
        let body = try bodyData(for: collection)

        // First submission
        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue((try? res.content.decode(ReportResponse.self))?.received == true)
            })

        // Second submission (worker retry)
        let body2 = try bodyData(for: collection)
        try app.test(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath,
                    body: body2, workerSecret: self.workerSecret)
                req.body = body2
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok, "Second (retry) POST must also succeed")
                XCTAssertTrue((try? res.content.decode(ReportResponse.self))?.received == true)
            })

        // Submission must still be "complete" (not rolled back or errored)
        let submission = try APISubmission.find(collection.submissionID, on: app.db).wait()
        XCTAssertEqual(submission?.status, "complete", "Submission must remain complete after duplicate result")

        // Two result records should exist — duplicates are appended, not rejected.
        // The view layer picks the latest, so both records are harmless.
        let resultCount = try APIResult.query(on: app.db)
            .filter(\.$submissionID == collection.submissionID)
            .count()
            .wait()
        XCTAssertEqual(resultCount, 2, "Each POST should persist one result record")
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
