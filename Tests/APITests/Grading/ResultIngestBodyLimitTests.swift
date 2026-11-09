// Tests/APITests/Grading/ResultIngestBodyLimitTests.swift
//
// `ResultRoutes.resultIngestBodyLimitBytes` (32 MB) is the result report's
// body limit: above the runner's own budget, so an over-budget report from an
// older runner reaches the server-side truncation instead of a 413 that leaves
// the submission unresolved (#1157). The route took the app default (10 MB)
// and the worker HMAC middleware collected at that default too, so the limit
// never applied.
//
// A body over the ingest limit is refused by Vapor's own stream collection,
// which the in-memory test transport does not exercise (it hands the route an
// already-collected body), so no test here asserts the 413.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct ResultIngestBodyLimitTests {
    private let workerSecret = "test-worker-secret"
    private let path = "/api/v1/worker/results"

    /// A report for `submissionID` whose one outcome carries `longResultBytes`
    /// of output: a body well past the 10 MB default.
    private func reportBody(submissionID: String, longResultBytes: Int) -> ByteBuffer {
        let longResult = String(repeating: "x", count: longResultBytes)
        let json = """
            {"collection":{"submissionID":"\(submissionID)","testSetupID":"setup_big","attemptNumber":1,\
            "buildStatus":"passed","compilerOutput":null,"outcomes":[{"testName":"t","testClass":null,\
            "tier":"public","status":"fail","shortResult":"failed","longResult":"\(longResult)",\
            "executionTimeMs":5,"memoryUsageBytes":null,"attemptNumber":1,"isFirstPassSuccess":false}],\
            "totalTests":1,"passCount":0,"failCount":1,"errorCount":0,"timeoutCount":0,\
            "executionTimeMs":5,"runnerVersion":"runner/1.0","timestamp":"2026-01-01T00:00:00Z"},\
            "diagnostics":null}
            """
        return ByteBuffer(string: json)
    }

    private func status(_ app: Application, body: ByteBuffer) async throws -> HTTPStatus {
        let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: workerSecret)
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = headers
                req.body = body
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func aReportOverTheDefaultButUnderTheIngestLimitIsAccepted() async throws {
        try await withTestApp(prefix: "chickadee-result-limit") { app in
            app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
            let courseID = try await makeTestCourse(on: app, code: "BIG101").requireID()
            try await makeTestSetup(on: app, id: "setup_big", courseID: courseID)
            try await APISubmission(
                id: "sub_big", testSetupID: "setup_big", zipPath: app.resultsDirectory + "sub_big.zip",
                attemptNumber: 1
            ).save(on: app.db)
            try await markClaimedForResultReport("sub_big", on: app.db)

            let body = reportBody(submissionID: "sub_big", longResultBytes: 12_000_000)
            let result = try await status(app, body: body)
            #expect(result == .ok)
            let submission = try #require(try await APISubmission.find("sub_big", on: app.db))
            #expect(submission.status == SubmissionStatus.complete.rawValue)
        }
    }
}
