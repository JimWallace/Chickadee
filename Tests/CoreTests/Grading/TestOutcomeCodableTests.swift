// Tests/CoreTests/Grading/TestOutcomeCodableTests.swift
//
// `TestOutcome`'s custom decoder: `points` defaults to 1, and `score`
// defaults from the status on records written before it existed.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct TestOutcomeCodableTests: ISO8601CodingSuite {

    @Test func testOutcomePointsDefaultsToOne() throws {
        let json = Data(
            """
            {
              "testName": "testFoo",
              "tier": "public",
              "status": "pass",
              "shortResult": "passed",
              "executionTimeMs": 42,
              "attemptNumber": 1,
              "isFirstPassSuccess": true
            }
            """.utf8)

        let outcome = try decoder.decode(TestOutcome.self, from: json)
        #expect(outcome.points == 1)
        #expect(outcome.testClass == nil)
        #expect(outcome.longResult == nil)
        #expect(outcome.memoryUsageBytes == nil)
    }

    @Test func testOutcomeExplicitPoints() throws {
        let json = Data(
            """
            {
              "testName": "testBar",
              "tier": "release",
              "status": "fail",
              "shortResult": "wrong answer",
              "longResult": "expected 42, got 0",
              "points": 3,
              "executionTimeMs": 10,
              "attemptNumber": 2,
              "isFirstPassSuccess": false
            }
            """.utf8)

        let outcome = try decoder.decode(TestOutcome.self, from: json)
        #expect(outcome.points == 3)
        #expect(outcome.longResult == "expected 42, got 0")
        #expect(outcome.isFirstPassSuccess == false)
    }

    @Test func testOutcomeScoreDefaultsFromStatusForOldRecords() throws {
        // A record predating partial credit has no `score`: a pass earns full
        // credit and a non-pass none, so existing results grade exactly as before.
        let passJSON = Data(
            #"{"testName":"ok","tier":"public","status":"pass","shortResult":"passed","executionTimeMs":1,"attemptNumber":1,"isFirstPassSuccess":true}"#
                .utf8)
        let failJSON = Data(
            #"{"testName":"bad","tier":"public","status":"fail","shortResult":"failed","executionTimeMs":1,"attemptNumber":1,"isFirstPassSuccess":false}"#
                .utf8)
        #expect(try decoder.decode(TestOutcome.self, from: passJSON).score == 1)
        #expect(try decoder.decode(TestOutcome.self, from: failJSON).score == 0)
    }

    @Test func testOutcomeExplicitScoreRoundTrips() throws {
        let outcome = TestOutcome(
            testName: "partial", testClass: nil, tier: .pub, status: .pass,
            shortResult: "3/4 cases passed", longResult: nil,
            score: 0.75, points: 4, executionTimeMs: 2,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true
        )
        let decoded = try decoder.decode(TestOutcome.self, from: encoder.encode(outcome))
        #expect(decoded == outcome)
        #expect(decoded.score == 0.75)
    }

    @Test func testOutcomeRoundTrip() throws {
        let outcome = TestOutcome(
            testName: "testBaz",
            testClass: "PublicTests",
            tier: .secret,
            status: .timeout,
            shortResult: "timed out",
            longResult: nil,
            points: 2,
            executionTimeMs: 5000,
            memoryUsageBytes: 1024,
            attemptNumber: 3,
            isFirstPassSuccess: false
        )
        let data = try encoder.encode(outcome)
        let decoded = try decoder.decode(TestOutcome.self, from: data)
        #expect(decoded == outcome)
    }
}
