// Tests/APITests/SubmissionQueryRoutesTests.swift
//
// Phase 3: tests for student-facing read endpoints.
//
//   GET /api/v1/submissions
//   GET /api/v1/submissions/:id
//   GET /api/v1/submissions/:id/results

import XCTest
import XCTVapor
@testable import APIServer
@testable import Core
import FluentSQLiteDriver
import Foundation

final class SubmissionQueryRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sqr-\(UUID().uuidString)/")
            .path

        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = dirs[0]
        app.testSetupsDirectory  = dirs[1]
        app.submissionsDirectory = dirs[2]

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(AddAttemptNumberToSubmissions())
        try await app.autoMigrate().get()

        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func insertSubmission(
        id: String,
        testSetupID: String = "setup_001",
        status: String = "pending",
        attemptNumber: Int = 1
    ) async throws -> APISubmission {
        let sub = APISubmission(
            id: id,
            testSetupID: testSetupID,
            zipPath: tmpDir + "submissions/\(id).zip",
            attemptNumber: attemptNumber,
            status: status
        )
        try await sub.save(on: app.db)
        return sub
    }

    private func insertResult(
        submissionID: String,
        collection: TestOutcomeCollection
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(collection), encoding: .utf8)!
        let result = APIResult(
            id: "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID: submissionID,
            collectionJSON: json
        )
        try await result.save(on: app.db)
    }

    private func makeCollection(
        submissionID: String,
        outcomes: [TestOutcome] = []
    ) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: outcomes,
            totalTests: outcomes.count,
            passCount: outcomes.filter { $0.status == .pass }.count,
            failCount: outcomes.filter { $0.status == .fail }.count,
            errorCount: outcomes.filter { $0.status == .error }.count,
            timeoutCount: outcomes.filter { $0.status == .timeout }.count,
            executionTimeMs: 100,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeOutcome(
        name: String,
        tier: TestTier = .pub,
        status: TestOutcomeStatus = .pass
    ) -> TestOutcome {
        TestOutcome(
            testName: name,
            testClass: nil,
            tier: tier,
            status: status,
            shortResult: status == .pass ? "passed" : "failed",
            longResult: nil,
            executionTimeMs: 10,
            memoryUsageBytes: nil,
            attemptNumber: 1,
            isFirstPassSuccess: status == .pass
        )
    }

    private func decodeCollection(from body: ByteBuffer) throws -> TestOutcomeCollection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(body.readableBytesView)
        return try decoder.decode(TestOutcomeCollection.self, from: data)
    }

    // MARK: - GET /api/v1/submissions

    func testListSubmissionsEmpty() throws {
        try app.test(.GET, "/api/v1/submissions") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionListResponse.self)
            XCTAssertTrue(body.submissions.isEmpty)
        }
    }

    func testListSubmissionsReturnsAll() async throws {
        try await insertSubmission(id: "sub_ls1", testSetupID: "setup_001")
        try await insertSubmission(id: "sub_ls2", testSetupID: "setup_002")

        try app.test(.GET, "/api/v1/submissions") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionListResponse.self)
            XCTAssertEqual(body.submissions.count, 2)
        }
    }

    func testListSubmissionsFilterByTestSetupID() async throws {
        try await insertSubmission(id: "sub_f1", testSetupID: "setup_AAA")
        try await insertSubmission(id: "sub_f2", testSetupID: "setup_BBB")
        try await insertSubmission(id: "sub_f3", testSetupID: "setup_AAA")

        try app.test(.GET, "/api/v1/submissions?testSetupID=setup_AAA") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionListResponse.self)
            XCTAssertEqual(body.submissions.count, 2)
            XCTAssertTrue(body.submissions.allSatisfy { $0.testSetupID == "setup_AAA" })
        }
    }

    func testListSubmissionsIncludesExpectedFields() async throws {
        try await insertSubmission(
            id: "sub_fields",
            testSetupID: "setup_001",
            status: "complete",
            attemptNumber: 3
        )

        try app.test(.GET, "/api/v1/submissions") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionListResponse.self)
            let sub = try XCTUnwrap(body.submissions.first { $0.submissionID == "sub_fields" })
            XCTAssertEqual(sub.testSetupID, "setup_001")
            XCTAssertEqual(sub.status, "complete")
            XCTAssertEqual(sub.attemptNumber, 3)
        }
    }

    // MARK: - GET /api/v1/submissions/:id

    func testGetSubmissionReturnsStatus() async throws {
        try await insertSubmission(
            id: "sub_gs1",
            testSetupID: "setup_001",
            status: "assigned",
            attemptNumber: 2
        )

        try app.test(.GET, "/api/v1/submissions/sub_gs1") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionStatusResponse.self)
            XCTAssertEqual(body.submissionID, "sub_gs1")
            XCTAssertEqual(body.testSetupID, "setup_001")
            XCTAssertEqual(body.status, "assigned")
            XCTAssertEqual(body.attemptNumber, 2)
        }
    }

    func testGetSubmissionReturnsSubmittedAt() async throws {
        try await insertSubmission(id: "sub_ts1")

        try app.test(.GET, "/api/v1/submissions/sub_ts1") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionStatusResponse.self)
            XCTAssertNotNil(body.submittedAt)
        }
    }

    func testGetSubmissionNotFound() throws {
        try app.test(.GET, "/api/v1/submissions/nonexistent") { res in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    // MARK: - GET /api/v1/submissions/:id/results

    func testGetResultsNotFoundForUnknownSubmission() throws {
        try app.test(.GET, "/api/v1/submissions/no_such_sub/results") { res in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testGetResultsNotFoundWhenNoneStored() async throws {
        try await insertSubmission(id: "sub_pending")

        try app.test(.GET, "/api/v1/submissions/sub_pending/results") { res in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testGetResultsReturnsCollection() async throws {
        try await insertSubmission(id: "sub_res1")
        let collection = makeCollection(
            submissionID: "sub_res1",
            outcomes: [makeOutcome(name: "test_alpha", tier: .pub, status: .pass)]
        )
        try await insertResult(submissionID: "sub_res1", collection: collection)

        try app.test(.GET, "/api/v1/submissions/sub_res1/results") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try self.decodeCollection(from: res.body)
            XCTAssertEqual(body.submissionID, "sub_res1")
            XCTAssertEqual(body.buildStatus, .passed)
            XCTAssertEqual(body.outcomes.count, 1)
            XCTAssertEqual(body.outcomes[0].testName, "test_alpha")
            XCTAssertEqual(body.passCount, 1)
            XCTAssertEqual(body.failCount, 0)
        }
    }

    func testGetResultsWithFailedBuild() async throws {
        try await insertSubmission(id: "sub_fail")
        let collection = TestOutcomeCollection(
            submissionID: "sub_fail",
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: .failed,
            compilerOutput: "make: *** [all] Error 1",
            outcomes: [],
            totalTests: 0,
            passCount: 0,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 50,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        try await insertResult(submissionID: "sub_fail", collection: collection)

        try app.test(.GET, "/api/v1/submissions/sub_fail/results") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try self.decodeCollection(from: res.body)
            XCTAssertEqual(body.buildStatus, .failed)
            XCTAssertTrue(body.outcomes.isEmpty)
            XCTAssertEqual(body.compilerOutput, "make: *** [all] Error 1")
        }
    }

    func testGetResultsFiltersBySingleTier() async throws {
        try await insertSubmission(id: "sub_tier1")
        let collection = makeCollection(
            submissionID: "sub_tier1",
            outcomes: [
                makeOutcome(name: "test_pub",     tier: .pub,     status: .pass),
                makeOutcome(name: "test_release", tier: .release, status: .fail),
                makeOutcome(name: "test_secret",  tier: .secret,  status: .pass),
                makeOutcome(name: "test_student", tier: .student, status: .error),
            ]
        )
        try await insertResult(submissionID: "sub_tier1", collection: collection)

        try app.test(.GET, "/api/v1/submissions/sub_tier1/results?tiers=public") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try self.decodeCollection(from: res.body)
            XCTAssertEqual(body.outcomes.count, 1)
            XCTAssertEqual(body.outcomes[0].testName, "test_pub")
            XCTAssertEqual(body.totalTests, 1)
            XCTAssertEqual(body.passCount, 1)
            XCTAssertEqual(body.failCount, 0)
            XCTAssertEqual(body.errorCount, 0)
        }
    }

    func testGetResultsFiltersByMultipleTiers() async throws {
        try await insertSubmission(id: "sub_tier2")
        let collection = makeCollection(
            submissionID: "sub_tier2",
            outcomes: [
                makeOutcome(name: "test_pub",     tier: .pub,     status: .pass),
                makeOutcome(name: "test_student", tier: .student, status: .fail),
                makeOutcome(name: "test_secret",  tier: .secret,  status: .pass),
            ]
        )
        try await insertResult(submissionID: "sub_tier2", collection: collection)

        try app.test(.GET, "/api/v1/submissions/sub_tier2/results?tiers=public,student") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try self.decodeCollection(from: res.body)
            XCTAssertEqual(body.outcomes.count, 2)
            XCTAssertEqual(body.totalTests, 2)
            XCTAssertEqual(body.passCount, 1)
            XCTAssertEqual(body.failCount, 1)
            XCTAssertFalse(body.outcomes.contains { $0.tier == .secret })
        }
    }

    func testGetResultsNoTierFilterReturnsAll() async throws {
        try await insertSubmission(id: "sub_all")
        let collection = makeCollection(
            submissionID: "sub_all",
            outcomes: [
                makeOutcome(name: "test_pub",    tier: .pub,    status: .pass),
                makeOutcome(name: "test_release",tier: .release,status: .pass),
                makeOutcome(name: "test_secret", tier: .secret, status: .pass),
            ]
        )
        try await insertResult(submissionID: "sub_all", collection: collection)

        try app.test(.GET, "/api/v1/submissions/sub_all/results") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try self.decodeCollection(from: res.body)
            XCTAssertEqual(body.outcomes.count, 3)
            XCTAssertEqual(body.totalTests, 3)
        }
    }
}
