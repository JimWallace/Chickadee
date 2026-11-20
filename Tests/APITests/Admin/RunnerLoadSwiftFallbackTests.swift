// Tests/APITests/Admin/RunnerLoadSwiftFallbackTests.swift
//
// Two parts of the admin card load math that `MetricsCardSeriesTests` does
// not reach:
//
// - `peakLoadPoint`: the "Max Load" headline picks the point with the highest
//   utilization ratio, and on a tie the one with more active jobs.
// - The Swift fallbacks of `runnerLoadPoints` and `runnerTimeseriesSummaries`,
//   which run for a driver without SQL. The test database is Postgres, so the
//   tests reach the fallbacks through `NonSQLDatabase`, a wrapper that
//   forwards every query but is not an `SQLDatabase`. Each fallback must give
//   the same result as the SQL path over the same rows.

import Fluent
import FluentKit
import Foundation
import SQLKit
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

/// A `Database` that forwards to another one and is not an `SQLDatabase`, so
/// code that checks `db as? any SQLDatabase` takes its non-SQL path.
private struct NonSQLDatabase: Database {
    let base: any Database

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        base.execute(schema: schema)
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        base.execute(enum: `enum`)
    }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.transaction { closure(NonSQLDatabase(base: $0)) }
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.withConnection { closure(NonSQLDatabase(base: $0)) }
    }
}

@Suite(.serialized) final class RunnerLoadSwiftFallbackTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-load-fallback")
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

    /// Per (bucket, runner) the fallback keeps the runner's peak, then sums
    /// the runners: two reports from one runner in a bucket are not added.
    @Test func runnerLoadPointsFallbackTakesEachRunnersPeakThenSums() async throws {
        try await withApp(app) { app in
            #expect(!(NonSQLDatabase(base: app.db) is any SQLDatabase))
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
            let fallback = try await app.diagnostics.runnerLoadPoints(
                since: since, on: NonSQLDatabase(base: app.db))

            #expect(fallback.map(\.bucketStart) == [anchor, anchor.addingTimeInterval(2 * bucket)])
            #expect(fallback.map(\.totalActive) == [5, 0])
            #expect(fallback.map(\.totalMax) == [6, 4])

            // Parity: the SQL path gives the same points over the same rows.
            let viaSQL = try await app.diagnostics.runnerLoadPoints(since: since, on: app.db)
            #expect(viaSQL.map(\.bucketStart) == fallback.map(\.bucketStart))
            #expect(viaSQL.map(\.totalActive) == fallback.map(\.totalActive))
            #expect(viaSQL.map(\.totalMax) == fallback.map(\.totalMax))
        }
    }

    /// The time-series fallback averages and peaks per-snapshot utilization
    /// per display bucket, and gives the same summaries as the SQL path.
    @Test func runnerTimeseriesSummariesFallbackMatchesTheSQLPath() async throws {
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

            let fallback = try await app.diagnostics.runnerTimeseriesSummaries(
                window: window, on: NonSQLDatabase(base: app.db))

            #expect(fallback.count == 2)
            #expect(fallback.first?.avgUtilizationPercent == 75)
            #expect(fallback.first?.maxUtilizationPercent == 100)
            #expect(fallback.last?.avgUtilizationPercent == 25)
            #expect(fallback.last?.maxUtilizationPercent == 25)

            let viaSQL = try await app.diagnostics.runnerTimeseriesSummaries(window: window, on: app.db)
            #expect(viaSQL == fallback)
        }
    }
}
