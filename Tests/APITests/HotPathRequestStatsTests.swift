import Foundation
import Testing

@testable import APIServer

@Suite struct HotPathRequestStatsTests {
    // MARK: - HotPathRoute

    @Test(arguments: [
        ("POST", "/api/v1/worker/request", HotPathRoute.workerPoll),
        ("POST", "/api/v1/worker/heartbeat", HotPathRoute.workerHeartbeat),
        ("GET", "/api/v1/submissions/sub_123", HotPathRoute.submissionStatusPoll),
    ])
    func routeMatchesItsHotPath(method: String, path: String, expected: HotPathRoute) {
        #expect(HotPathRoute(method: method, path: path) == expected)
    }

    /// The sibling routes of the status poll still persist a row each, so
    /// counting them here would count them twice.
    @Test(arguments: [
        ("GET", "/api/v1/submissions/"),
        ("GET", "/api/v1/submissions/sub_123/results"),
        ("GET", "/api/v1/submissions"),
        ("POST", "/api/v1/submissions/sub_123"),
        ("GET", "/api/v1/worker/request"),
        ("POST", "/api/v1/worker/results"),
    ])
    func routeIgnoresOtherRequests(method: String, path: String) {
        #expect(HotPathRoute(method: method, path: path) == nil)
    }

    // MARK: - LatencyHistogram

    @Test func emptyHistogramHasNoPercentiles() {
        let histogram = LatencyHistogram()
        #expect(histogram.requestCount == 0)
        #expect(histogram.percentileMs(0.5) == nil)
        #expect(histogram.maxMs == nil)
    }

    @Test func percentileIsTheBucketUpperBound() {
        var histogram = LatencyHistogram()
        for _ in 0..<90 { histogram.record(durationMs: 3, isError: false) }
        for _ in 0..<10 { histogram.record(durationMs: 40, isError: true) }

        #expect(histogram.requestCount == 100)
        #expect(histogram.errorCount == 10)
        #expect(histogram.percentileMs(0.50) == 5)
        #expect(histogram.percentileMs(0.90) == 5)
        #expect(histogram.percentileMs(0.95) == 40)
        #expect(histogram.maxMs == 40)
    }

    /// A bucket bound above the largest duration seen would overstate the
    /// latency, so the percentile stops at the maximum.
    @Test func percentileIsCappedAtTheMaximum() {
        var histogram = LatencyHistogram()
        histogram.record(durationMs: 120, isError: false)
        #expect(histogram.percentileMs(0.5) == 120)
    }

    @Test func overflowBucketReportsTheMaximum() {
        var histogram = LatencyHistogram()
        histogram.record(durationMs: 12_000, isError: false)
        histogram.record(durationMs: 30_000, isError: false)
        #expect(histogram.percentileMs(0.5) == 30_000)
        #expect(histogram.percentileMs(0.99) == 30_000)
    }

    @Test func mergeAddsCountsAndKeepsTheLargerMaximum() {
        var first = LatencyHistogram()
        first.record(durationMs: 2, isError: false)
        var second = LatencyHistogram()
        second.record(durationMs: 300, isError: true)

        first.merge(second)
        #expect(first.requestCount == 2)
        #expect(first.errorCount == 1)
        #expect(first.maxMs == 300)
        #expect(first.percentileMs(1.0) == 300)
    }

    // MARK: - HotPathRequestStats

    @Test func snapshotReportsEveryRouteEvenWithNoTraffic() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let stats = HotPathRequestStats(startedAt: start)
        let snapshot = await stats.snapshot(now: start)

        #expect(snapshot.countingSince == start)
        #expect(snapshot.windowMinutes == HotPathRequestStats.windowMinutes)
        #expect(snapshot.routes.map(\.route) == HotPathRoute.allCases.map(\.rawValue))
        #expect(snapshot.routes.allSatisfy { $0.sinceStart.requestCount == 0 && $0.peakRequestsPerMinute == 0 })
    }

    @Test func windowDropsOldMinutesButSinceStartKeepsThem() async throws {
        let start = Date(timeIntervalSince1970: 6_000_000)
        let stats = HotPathRequestStats(startedAt: start)

        // Three polls in the first minute, then one poll two hours later.
        for _ in 0..<3 {
            await stats.record(route: .workerPoll, durationMs: 4, statusCode: 204, at: start)
        }
        let later = start.addingTimeInterval(2 * 3600)
        await stats.record(route: .workerPoll, durationMs: 60, statusCode: 401, at: later)

        let snapshot = await stats.snapshot(now: later)
        let poll = try #require(snapshot.routes.first { $0.route == HotPathRoute.workerPoll.rawValue })
        #expect(poll.sinceStart.requestCount == 4)
        #expect(poll.sinceStart.errorCount == 1)
        #expect(poll.lastWindow.requestCount == 1)
        #expect(poll.lastWindow.errorCount == 1)
        #expect(poll.lastWindow.p50Ms == 60)
        #expect(poll.peakRequestsPerMinute == 1)
    }

    @Test func peakIsTheBusiestMinuteInTheWindow() async throws {
        let start = Date(timeIntervalSince1970: 6_000_000)
        let stats = HotPathRequestStats(startedAt: start)

        for _ in 0..<5 {
            await stats.record(route: .submissionStatusPoll, durationMs: 2, statusCode: 200, at: start)
        }
        let nextMinute = start.addingTimeInterval(60)
        for _ in 0..<2 {
            await stats.record(route: .submissionStatusPoll, durationMs: 2, statusCode: 200, at: nextMinute)
        }

        let snapshot = await stats.snapshot(now: nextMinute)
        let status = try #require(
            snapshot.routes.first { $0.route == HotPathRoute.submissionStatusPoll.rawValue })
        #expect(status.lastWindow.requestCount == 7)
        #expect(status.peakRequestsPerMinute == 5)
    }

    /// The snapshot filters by its own `now` too: minutes that aged out of
    /// the window after the last request are not reported.
    @Test func snapshotExcludesMinutesThatAgedOutSinceTheLastRequest() async throws {
        let start = Date(timeIntervalSince1970: 6_000_000)
        let stats = HotPathRequestStats(startedAt: start)
        await stats.record(route: .workerHeartbeat, durationMs: 8, statusCode: 200, at: start)

        let snapshot = await stats.snapshot(now: start.addingTimeInterval(3 * 3600))
        let heartbeat = try #require(
            snapshot.routes.first { $0.route == HotPathRoute.workerHeartbeat.rawValue })
        #expect(heartbeat.sinceStart.requestCount == 1)
        #expect(heartbeat.lastWindow.requestCount == 0)
        #expect(heartbeat.lastWindow.p95Ms == nil)
        #expect(heartbeat.peakRequestsPerMinute == 0)
    }
}
