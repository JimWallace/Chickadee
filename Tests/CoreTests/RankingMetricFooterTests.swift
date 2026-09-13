// Tests/CoreTests/RankingMetricFooterTests.swift
//
// The footer's optional `metric`: the unclamped number a class activity ranks
// on (docs/class-activities.md). It is the second route by which a footer's
// number reaches an observable output — `score` was the only one — and,
// unlike `score`, it is never derived: a script that reports none has no
// ranking position rather than a default one.

import Core
import Foundation
import Testing

@Suite struct RankingMetricFooterTests {

    private func interpret(stdout: String, exitCode: Int32 = 0) -> InterpretedScriptResult {
        interpretScriptOutput(
            ScriptOutput(
                exitCode: exitCode, stdout: stdout, stderr: "", executionTimeMs: 0, timedOut: false))
    }

    @Test func metricIsSurfacedUnclampedAndLeavesScoreAlone() {
        let result = interpret(stdout: "{\"shortResult\":\"tour 1234.5\",\"metric\":1234.5}")
        #expect(result.metric == 1234.5)
        #expect(result.score == 1)  // a pass with no footer score is still full credit
    }

    @Test(arguments: [("-7", -7.0), ("2.5e3", 2500.0), ("0", 0.0), ("1e-3", 0.001)])
    func metricAcceptsAnyNumber(literal: String, expected: Double) {
        let result = interpret(stdout: "{\"shortResult\":\"x\",\"metric\":\(literal)}")
        #expect(result.shortResult == "x")
        #expect(result.metric.map { abs($0 - expected) < 1e-12 } == true)
    }

    @Test func absentMetricIsNilNotZero() {
        #expect(interpret(stdout: "{\"shortResult\":\"x\",\"score\":0.5}").metric == nil)
        #expect(interpret(stdout: "plain text").metric == nil)
        #expect(interpret(stdout: "").metric == nil)
    }

    @Test func nonNumericMetricIsIgnored() {
        let result = interpret(stdout: "{\"shortResult\":\"x\",\"metric\":\"fast\"}")
        #expect(result.metric == nil)
        #expect(result.shortResult == "x")
    }

    @Test func metricIsOrthogonalToTheExitCode() {
        let result = interpret(stdout: "{\"shortResult\":\"lost\",\"metric\":3}", exitCode: 1)
        #expect(result.status == .fail)
        #expect(result.score == 0)
        #expect(result.metric == 3)
    }

    // MARK: - TestOutcome carries it, and a nil one changes no stored bytes

    @Test func testOutcomeMetricRoundTripsAndNilIsOmitted() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let ranked = TestOutcome(
            testName: "t", testClass: nil, tier: .pub, status: .pass,
            shortResult: "ok", longResult: nil, metric: 42.5,
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
        let decoded = try decoder.decode(TestOutcome.self, from: encoder.encode(ranked))
        #expect(decoded == ranked)
        #expect(decoded.metric == 42.5)

        // A script that reports no metric must produce exactly the JSON it
        // always has: no `metric` key at all, not `"metric":null`.
        let unranked = TestOutcome(
            testName: "t", testClass: nil, tier: .pub, status: .pass,
            shortResult: "ok", longResult: nil,
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
        let json = try #require(String(data: encoder.encode(unranked), encoding: .utf8))
        #expect(!json.contains("metric"))

        // And an old record with no key decodes to nil.
        let legacy = Data(
            #"{"testName":"t","tier":"public","status":"pass","shortResult":"ok","executionTimeMs":1,"attemptNumber":1,"isFirstPassSuccess":true}"#
                .utf8)
        #expect(try decoder.decode(TestOutcome.self, from: legacy).metric == nil)
    }
}
