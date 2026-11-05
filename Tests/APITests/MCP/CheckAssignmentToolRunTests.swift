// Tests that check_assignment loads the stored validation run into the
// snapshot (#2747), end to end through `AuthoringSnapshot.load` and a real test
// database. The checks themselves are tested in `RunAuthoringCheckTests`.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CheckAssignmentToolRunTests {
    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":2}\
        ],"timeLimitSeconds":10}
        """

    private func collectionJSON(submissionID: String, executionTimeMs: Int) throws -> String {
        let outcome = TestOutcome(
            testName: "test_a", testClass: nil, tier: .pub, status: .pass, shortResult: "ok",
            longResult: nil, executionTimeMs: executionTimeMs, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: true)
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: "setup_chk_run", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 1, failCount: 0,
            errorCount: 0, timeoutCount: 0, executionTimeMs: executionTimeMs, runnerVersion: "shell-runner/1.0",
            timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: try encoder.encode(collection), encoding: .utf8))
    }

    @Test func theSolutionRunReachesTheChecks() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_chk_run", manifest: manifest)
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == mcpTestSubject).first())
            try await makeTestSubmission(
                on: app, id: "sub_chk_run", setupID: "setup_chk_run", userID: tester.requireID(),
                kind: APISubmission.Kind.validation)
            try await makeTestResult(
                on: app, submissionID: "sub_chk_run",
                collectionJSON: collectionJSON(submissionID: "sub_chk_run", executionTimeMs: 8000))
            assignment.validationSubmissionID = "sub_chk_run"
            try await assignment.save(on: app.db)

            let output = try await CheckAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), mcpContext(app, scopes: [.read]))
            #expect(output.warnings.isEmpty)
            #expect(output.findings.map(\.checkID) == ["timing.margin"])
            #expect(output.findings.first?.location == .suiteItem("test_a.sh"))
        }
    }
}
