// Tests/APITests/Admin/RunnerLoadPointsTests.swift
//
// Two parts of the admin card load math that `MetricsCardSeriesTests` does
// not reach:
//
// - `peakLoadPoint`: the "Max Load" headline picks the point with the highest
//   utilization ratio, and on a tie the one with more active jobs.
// - The SQL aggregation of `runnerLoadPoints` and `runnerTimeseriesSummaries`:
//   per bucket the load keeps each runner's peak, then sums the runners, and
//   rows before the window are excluded. These cases came from the tests of
//   the removed non-SQL fallbacks (#3159); they now run on the SQL path only.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The headline peak rule, with no database.
@Suite struct PeakLoadPointTests {
    private let service = OperationalDiagnosticsService(
        configuration: AppConfig.testDefaults(authMode: .local).diagnostics)

    private func point(_ active: Int, _ max: Int) -> RunnerLoadPoint {
        RunnerLoadPoint(bucketStart: Date(timeIntervalSince1970: 0), totalActive: active, totalMax: max)
    }

    @Test func noPointWithCapacityGivesNoPeak() {
        #expect(service.peakLoadPoint(from: []) == nil)
        #expect(service.peakLoadPoint(from: [point(3, 0)]) == nil)
    }

    /// A later point with a higher ratio replaces the first, even with fewer
    /// active jobs.
    @Test func aHigherRatioReplacesThePeak() throws {
        let peak = try #require(service.peakLoadPoint(from: [point(4, 10), point(3, 4)]))
        #expect(peak.active == 3)
        #expect(peak.max == 4)
    }

    /// A later point with a lower ratio does not replace the peak, even with
    /// more active jobs.
    @Test func aLowerRatioKeepsThePeak() throws {
        let peak = try #require(service.peakLoadPoint(from: [point(3, 4), point(6, 10)]))
        #expect(peak.active == 3)
        #expect(peak.max == 4)
    }

    /// On an equal ratio, the point with more active jobs wins, in either
    /// order.
    @Test func anEqualRatioPrefersMoreActiveJobs() throws {
        let later = try #require(service.peakLoadPoint(from: [point(1, 2), point(4, 8)]))
        #expect(later.active == 4)
        #expect(later.max == 8)
        let earlier = try #require(service.peakLoadPoint(from: [point(4, 8), point(1, 2)]))
        #expect(earlier.active == 4)
        #expect(earlier.max == 8)
    }

    /// A point with no capacity is skipped, not read as a ratio.
    @Test func aPointWithNoCapacityIsSkipped() throws {
        let peak = try #require(service.peakLoadPoint(from: [point(5, 0), point(1, 4)]))
        #expect(peak.active == 1)
        #expect(peak.max == 4)
    }
}

@Suite(.serialized) final class RunnerLoadPointsTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-load-points")
    }

    private func saveSnapshot(runner: String, at date: Date, active: Int, max: Int) async throws {
        try await RunnerSnapshot(
            runnerID: runner,
            recordedAt: date,
            activeJobs: active,
            maxJobs: max,
            availableCapacity: Swift.max(0, max - active),
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        ).save(on: app.db)
    }

    /// Per (bucket, runner) the load keeps the runner's peak, then sums the
    /// runners: two reports from one runner in a bucket are not added.
    @Test func runnerLoadPointsTakeEachRunnersPeakThenSum() async throws {
        try await withApp(app) { app in
            let bucket = 300.0
            let now = Date()
            // The start of a 5-minute bucket well inside the last hour, so
            // every offset below lands in a known bucket.
            let anchor = Date(
                timeIntervalSince1970: (now.timeIntervalSince1970 / bucket).rounded(.down) * bucket - 4 * bucket)
            // Bucket A: r1 reports 1/4 then 3/4; r2 reports 2/2.
            try await saveSnapshot(runner: "r1", at: anchor.addingTimeInterval(10), active: 1, max: 4)
            try await saveSnapshot(runner: "r1", at: anchor.addingTimeInterval(100), active: 3, max: 4)
            try await saveSnapshot(runner: "r2", at: anchor.addingTimeInterval(200), active: 2, max: 2)
            // Bucket B, two buckets later: r1 alone at 0/4.
            try await saveSnapshot(runner: "r1", at: anchor.addingTimeInterval(2 * bucket + 30), active: 0, max: 4)
            // Before the window: excluded.
            try await saveSnapshot(runner: "r1", at: now.addingTimeInterval(-7200), active: 4, max: 4)

            let since = now.addingTimeInterval(-3600)
            let points = try await app.diagnostics.runnerLoadPoints(since: since, on: app.db)

            #expect(points.map(\.bucketStart) == [anchor, anchor.addingTimeInterval(2 * bucket)])
            #expect(points.map(\.totalActive) == [5, 0])
            #expect(points.map(\.totalMax) == [6, 4])
        }
    }

    /// The time series averages and peaks per-snapshot utilization per
    /// display bucket, and excludes rows before the window.
    @Test func runnerTimeseriesSummariesExcludeRowsBeforeTheWindow() async throws {
        try await withApp(app) { app in
            let now = Date()
            let window = BucketWindow.resolve(
                hours: 1, bucketMinutes: 30, defaultHours: 24, now: now
            ).window
            // Bucket 0: 2/4 (50%) and 4/4 (100%).
            try await saveSnapshot(runner: "r1", at: now.addingTimeInterval(-3000), active: 2, max: 4)
            try await saveSnapshot(runner: "r1", at: now.addingTimeInterval(-2700), active: 4, max: 4)
            // Bucket 1: 1/4 (25%).
            try await saveSnapshot(runner: "r2", at: now.addingTimeInterval(-1200), active: 1, max: 4)
            // Before the window: excluded.
            try await saveSnapshot(runner: "r2", at: now.addingTimeInterval(-7200), active: 4, max: 4)

            let summaries = try await app.diagnostics.runnerTimeseriesSummaries(window: window, on: app.db)

            #expect(summaries.count == 2)
            #expect(summaries.first?.avgUtilizationPercent == 75)
            #expect(summaries.first?.maxUtilizationPercent == 100)
            #expect(summaries.last?.avgUtilizationPercent == 25)
            #expect(summaries.last?.maxUtilizationPercent == 25)
        }
    }
}
