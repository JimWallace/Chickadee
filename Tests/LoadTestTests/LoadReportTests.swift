import Core
import Foundation
import Testing

@testable import chickadee_loadtest

@Suite struct LoadReportTests {
    @Test func reportWarnsWhenARunnerPollClaimedAJob() {
        let summary = LatencySummary(durationsMs: [2, 4], statusCounts: [200: 1, 204: 1], transportErrors: 0)
        let lines = LoadReport.lines(for: .runnerPoll, summary: summary, durationSeconds: 2)
        #expect(lines.first == LoadScenario.runnerPoll.rawValue)
        #expect(lines.contains("  requests:  2 (1 per second)"))
        #expect(lines.contains("  statuses:  200: 1, 204: 1"))
        #expect(lines.contains { $0.contains("WARNING") })
    }

    @Test func reportExplainsAnUnauthorizedStatusPoll() {
        let summary = LatencySummary(durationsMs: [1], statusCounts: [401: 1], transportErrors: 0)
        let lines = LoadReport.lines(for: .statusPoll, summary: summary, durationSeconds: 10)
        #expect(lines.contains { $0.contains("session cookie") })
        #expect(!lines.contains { $0.contains("WARNING") })
    }

    @Test(arguments: [(1.0, "1"), (2.25, "2.3"), (0.04, "0"), (12.5, "12.5")])
    func numbersRoundToOneDecimal(value: Double, expected: String) {
        #expect(LoadReport.format(value) == expected)
    }
}
