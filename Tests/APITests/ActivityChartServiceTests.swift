// Tests/APITests/ActivityChartServiceTests.swift
//
// Coverage for the admin dashboard "active users over time" chart: the
// distinct-users-per-bucket aggregation and the retention reaper.  The
// per-user insert throttle is pure (no app/DB) and lives in
// ActivityEventThrottleTests below.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ActivityChartServiceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-activitychart")
    }

    /// Creates a real user (the events table FK-references `users`) and returns
    /// its id.  Usernames must be unique within a test's fresh DB.
    private func makeUser(_ username: String) async throws -> UUID {
        let user = try await makeTestUser(on: app, username: username)
        return try #require(user.id)
    }

    /// Inserts an activity event for `userID` and back-dates `created_at` to
    /// `secondsAgo` before `now`.  `@Timestamp(on: .create)` only fires on the
    /// first insert, so a second save with an explicit `createdAt` preserves
    /// the override (portable across SQLite and Postgres) — same trick as the
    /// audit-log reaper tests.
    @discardableResult
    private func seedEvent(
        userID: UUID,
        secondsAgo: TimeInterval,
        now: Date = Date()
    ) async throws -> UUID {
        let event = APIUserActivityEvent(userID: userID, role: "student")
        try await event.save(on: app.db)
        let id = try #require(event.id)
        event.createdAt = now.addingTimeInterval(-secondsAgo)
        try await event.save(on: app.db)
        return id
    }

    // MARK: - Aggregation

    @Test func chartData_dayWindowHas24HourlyBuckets() async throws {
        try await withApp(app) { _ in
            let data = try await ActivityChartService.chartData(window: .day, on: app.db)
            #expect(data.window == "24h")
            #expect(data.buckets.count == 24)
        }
    }

    @Test func chartData_weekHas7Buckets_monthHas30() async throws {
        try await withApp(app) { _ in
            let week = try await ActivityChartService.chartData(window: .week, on: app.db)
            let month = try await ActivityChartService.chartData(window: .month, on: app.db)
            #expect(week.buckets.count == 7)
            #expect(month.buckets.count == 30)
        }
    }

    @Test func chartData_countsDistinctUsersPerBucket() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let userA = try await makeUser("activity_user_a")
            let userB = try await makeUser("activity_user_b")

            // Two pings from userA plus one from userB, all ~30 minutes ago →
            // they all land in the most recent hourly bucket and collapse to a
            // distinct count of 2.
            try await seedEvent(userID: userA, secondsAgo: 30 * 60, now: now)
            try await seedEvent(userID: userA, secondsAgo: 31 * 60, now: now)
            try await seedEvent(userID: userB, secondsAgo: 29 * 60, now: now)
            // One ping ~90 minutes ago → a different (earlier) bucket.
            try await seedEvent(userID: userA, secondsAgo: 90 * 60, now: now)

            let data = try await ActivityChartService.chartData(window: .day, on: app.db, now: now)
            let total = data.buckets.reduce(0) { $0 + $1.count }
            // Last bucket: {A, B} = 2.  An earlier bucket: {A} = 1.  Total 3.
            #expect(data.buckets.last?.count == 2)
            #expect(total == 3)
        }
    }

    @Test func chartData_excludesEventsOutsideWindow() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let user = try await makeUser("activity_user_outside")
            // 25 hours ago is outside the 24h window entirely.
            try await seedEvent(userID: user, secondsAgo: 25 * 3600, now: now)
            let data = try await ActivityChartService.chartData(window: .day, on: app.db, now: now)
            let total = data.buckets.reduce(0) { $0 + $1.count }
            #expect(total == 0)
        }
    }

    @Test func chartData_emptyTableYieldsZeroedBuckets() async throws {
        try await withApp(app) { _ in
            let data = try await ActivityChartService.chartData(window: .month, on: app.db)
            #expect(data.buckets.count == 30)
            let total = data.buckets.reduce(0) { $0 + $1.count }
            #expect(total == 0)
        }
    }

    // MARK: - Reaper

    @Test func reaper_deletesEventsOlderThanMaxAge() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let user = try await makeUser("activity_reaper_user")
            let stale = try await seedEvent(userID: user, secondsAgo: 40 * 86_400, now: now)
            let fresh = try await seedEvent(userID: user, secondsAgo: 2 * 86_400, now: now)

            try await reapStaleActivityEvents(
                on: app.db,
                logger: app.logger,
                maxAge: activityEventDefaultMaxAge,
                now: now
            )

            let staleGone = try await APIUserActivityEvent.find(stale, on: app.db) == nil
            let freshKept = try await APIUserActivityEvent.find(fresh, on: app.db) != nil
            #expect(staleGone, "Events older than maxAge should be deleted")
            #expect(freshKept, "Events inside the retention window must be preserved")
        }
    }

    @Test func reaper_zeroMaxAgeIsNoOp() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let user = try await makeUser("activity_reaper_noop_user")
            let old = try await seedEvent(userID: user, secondsAgo: 200 * 86_400, now: now)
            try await reapStaleActivityEvents(on: app.db, logger: app.logger, maxAge: 0, now: now)
            let stillThere = try await APIUserActivityEvent.find(old, on: app.db) != nil
            #expect(stillThere, "maxAge == 0 must be a no-op")
        }
    }
}

/// Pure unit tests for the per-user insert throttle — no app or DB, so this is
/// a plain struct suite.
@Suite struct ActivityEventThrottleTests {

    @Test func recordsOncePerWindow() async {
        let throttle = ActivityEventThrottle(window: 300)
        let user = UUID()
        let t0 = Date()
        #expect(await throttle.shouldRecord(userID: user, now: t0) == true)
        #expect(await throttle.shouldRecord(userID: user, now: t0.addingTimeInterval(60)) == false)
        // Past the window → records again.
        #expect(await throttle.shouldRecord(userID: user, now: t0.addingTimeInterval(301)) == true)
    }

    @Test func isPerUser() async {
        let throttle = ActivityEventThrottle(window: 300)
        let now = Date()
        #expect(await throttle.shouldRecord(userID: UUID(), now: now) == true)
        // A different user is independent even within the same instant.
        #expect(await throttle.shouldRecord(userID: UUID(), now: now) == true)
    }
}
