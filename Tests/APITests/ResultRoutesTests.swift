import XCTest
import XCTVapor
@testable import APIServer
@testable import Core
import Foundation

final class ResultRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpResultsDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        // Use a temp directory so tests don't pollute the project directory
        tmpResultsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-test-results-\(UUID().uuidString)/")
            .path
        try FileManager.default.createDirectory(
            atPath: tmpResultsDir,
            withIntermediateDirectories: true
        )

        app.resultsDirectory = tmpResultsDir
        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
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

    // MARK: - Tests

    func testReportResultsReturnsReceived() throws {
        let collection = makeCollection()
        let body = try bodyData(for: collection)

        try app.test(.POST, "/api/v1/worker/results", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let response = try res.content.decode(ReportResponse.self)
            XCTAssertTrue(response.received)
        })
    }

    func testReportResultsWritesFileToDisk() throws {
        let collection = makeCollection(submissionID: "sub_disktest")
        let body = try bodyData(for: collection)

        try app.test(.POST, "/api/v1/worker/results", beforeRequest: { req in
            req.headers.contentType = .json
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
        let body = try bodyData(for: collection)

        try app.test(.POST, "/api/v1/worker/results", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let response = try res.content.decode(ReportResponse.self)
            XCTAssertTrue(response.received)
        })
    }

    func testReportResultsRejectsMalformedJSON() throws {
        try app.test(.POST, "/api/v1/worker/results", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: "not valid json")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unprocessableEntity)
        })
    }

    func testReportResultsRejectsEmptyBody() throws {
        try app.test(.POST, "/api/v1/worker/results", beforeRequest: { req in
            req.headers.contentType = .json
        }, afterResponse: { res in
            // Either 400 or 422 is acceptable for empty body
            XCTAssertTrue(
                res.status == .badRequest || res.status == .unprocessableEntity,
                "Expected 400 or 422, got \(res.status)"
            )
        })
    }
}
