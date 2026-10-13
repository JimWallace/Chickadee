import Core
import Foundation
import Testing

@testable import chickadee_loadtest

@Suite struct LatencySummaryTests {
    @Test func emptySummaryHasNoPercentiles() {
        let summary = LatencySummary(durationsMs: [], statusCounts: [:], transportErrors: 2)
        #expect(summary.requestCount == 0)
        #expect(summary.transportErrors == 2)
        #expect(summary.p50Ms == nil)
        #expect(summary.maxMs == nil)
    }

    @Test func percentilesUseTheNearestRank() {
        let durations = (1...100).map(Double.init).shuffled()
        let summary = LatencySummary(durationsMs: durations, statusCounts: [204: 100], transportErrors: 0)
        #expect(summary.requestCount == 100)
        #expect(summary.p50Ms == 50)
        #expect(summary.p95Ms == 95)
        #expect(summary.p99Ms == 99)
        #expect(summary.maxMs == 100)
    }

    @Test func singleSampleIsEveryPercentile() {
        let summary = LatencySummary(durationsMs: [7.5], statusCounts: [200: 1], transportErrors: 0)
        #expect(summary.p50Ms == 7.5)
        #expect(summary.p99Ms == 7.5)
    }

    @Test func recorderKeepsTheScenariosApart() async {
        let recorder = LatencyRecorder()
        await recorder.record(.runnerPoll, statusCode: 204, durationMs: 3)
        await recorder.record(.runnerPoll, statusCode: 401, durationMs: 1)
        await recorder.recordTransportError(.statusPoll)

        let poll = await recorder.summary(for: .runnerPoll)
        let status = await recorder.summary(for: .statusPoll)
        #expect(poll.requestCount == 2)
        #expect(poll.statusCounts == [204: 1, 401: 1])
        #expect(status.requestCount == 0)
        #expect(status.transportErrors == 1)
    }
}
