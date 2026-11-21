// Tests/CoreTests/Grading/TestOutcomeCollectionCodableTests.swift
//
// `TestOutcomeCollection`'s custom decoder: the point totals fall back to
// the test counts on records written before they existed.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct TestOutcomeCollectionCodableTests: ISO8601CodingSuite {

    @Test func collectionTotalPointsFallsBackToTotalTests() throws {
        // Old JSON without totalPoints/earnedPoints/warnings/jobStartedAt
        let json = Data(
            """
            {
              "submissionID": "sub_001",
              "testSetupID": "setup_001",
              "attemptNumber": 1,
              "buildStatus": "passed",
              "outcomes": [],
              "totalTests": 5,
              "passCount": 3,
              "failCount": 2,
              "errorCount": 0,
              "timeoutCount": 0,
              "executionTimeMs": 500,
              "runnerVersion": "shell-runner/1.0",
              "timestamp": "1970-01-01T00:00:00Z"
            }
            """.utf8)

        let col = try decoder.decode(TestOutcomeCollection.self, from: json)
        #expect(col.totalPoints == 5)  // falls back to totalTests
        #expect(col.earnedPoints == 3)  // falls back to passCount
        #expect(col.warnings.isEmpty)  // defaults to empty
        #expect(col.jobStartedAt == nil)  // optional, absent
    }

    @Test func collectionExplicitPointsPreserved() throws {
        let outcome = TestOutcome(
            testName: "t1", testClass: nil, tier: .pub, status: .pass,
            shortResult: "passed", longResult: nil,
            points: 4, executionTimeMs: 10,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true
        )
        let col = TestOutcomeCollection(
            submissionID: "sub_002", testSetupID: "setup_002",
            attemptNumber: 1, buildStatus: .passed, compilerOutput: nil,
            outcomes: [outcome],
            totalTests: 1, passCount: 1, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 10,
            totalPoints: 4, earnedPoints: 4,
            warnings: ["file renamed"],
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(col)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        #expect(decoded.totalPoints == 4)
        #expect(decoded.earnedPoints == 4)
        #expect(decoded.warnings == ["file renamed"])
    }

    @Test func collectionFractionalEarnedPointsRoundTrips() throws {
        // Partial credit makes earnedPoints fractional; it must survive the
        // JSON round trip (it is the grade numerator).
        let col = TestOutcomeCollection(
            submissionID: "s", testSetupID: "t",
            attemptNumber: 1, buildStatus: .passed, compilerOutput: nil,
            outcomes: [],
            totalTests: 4, passCount: 3, failCount: 1, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 1,
            totalPoints: 4, earnedPoints: 2.75,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: encoder.encode(col))
        #expect(decoded.earnedPoints == 2.75)
    }

    @Test func collectionRoundTrip() throws {
        let col = TestOutcomeCollection(
            submissionID: "sub_rt", testSetupID: "setup_rt",
            attemptNumber: 2, buildStatus: .failed,
            compilerOutput: "make: no rule for target",
            outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 0,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try encoder.encode(col)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        #expect(decoded.submissionID == "sub_rt")
        #expect(decoded.buildStatus == .failed)
        #expect(decoded.compilerOutput == "make: no rule for target")
        #expect(decoded.outcomes.isEmpty)
    }
}
