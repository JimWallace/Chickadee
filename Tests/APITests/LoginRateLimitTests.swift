// Tests/APITests/LoginRateLimitTests.swift
//
// LoginAttemptService semantics (sliding IP window, username lockout) and —
// the point of #1154 — that the counts are shared across Application
// instances backed by the same database, so brute-force protection holds in
// a multi-process deployment.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LoginRateLimitTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-loginrl")
    }

    @Test func ipRateLimitTrips429AfterCap() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let max = 3
            var results: [Bool] = []
            for _ in 0..<4 {
                results.append(
                    try await LoginAttemptService.recordAndCheckIP(
                        ip: "1.2.3.4", now: now, windowSeconds: 60, max: max, on: app.db))
            }
            #expect(results == [true, true, true, false])
        }
    }

    @Test func ipRateLimitResetsAfterWindow() async throws {
        try await withApp(app) { _ in
            let start = Date()
            let later = start.addingTimeInterval(61)

            _ = try await LoginAttemptService.recordAndCheckIP(
                ip: "1.2.3.4", now: start, windowSeconds: 60, max: 1, on: app.db)
            let blocked = try await LoginAttemptService.recordAndCheckIP(
                ip: "1.2.3.4", now: start, windowSeconds: 60, max: 1, on: app.db)
            #expect(!blocked)

            let allowedLater = try await LoginAttemptService.recordAndCheckIP(
                ip: "1.2.3.4", now: later, windowSeconds: 60, max: 1, on: app.db)
            #expect(allowedLater)
        }
    }

    @Test func usernameLockoutAfterThreshold() async throws {
        try await withApp(app) { _ in
            let now = Date()
            for _ in 0..<5 {
                try await LoginAttemptService.recordFailure(
                    username: "alice", now: now, windowSeconds: 900, on: app.db)
            }
            let locked = try await LoginAttemptService.isLocked(
                username: "alice", now: now, windowSeconds: 900, threshold: 5, on: app.db)
            #expect(locked)
        }
    }

    @Test func usernameLockoutNotTrippedBelowThreshold() async throws {
        try await withApp(app) { _ in
            let now = Date()
            for _ in 0..<3 {
                try await LoginAttemptService.recordFailure(
                    username: "alice", now: now, windowSeconds: 900, on: app.db)
            }
            let locked = try await LoginAttemptService.isLocked(
                username: "alice", now: now, windowSeconds: 900, threshold: 5, on: app.db)
            #expect(!locked)
        }
    }

    @Test func clearFailuresResetsLockout() async throws {
        try await withApp(app) { _ in
            let now = Date()
            for _ in 0..<5 {
                try await LoginAttemptService.recordFailure(
                    username: "alice", now: now, windowSeconds: 900, on: app.db)
            }
            let lockedBefore = try await LoginAttemptService.isLocked(
                username: "alice", now: now, windowSeconds: 900, threshold: 5, on: app.db)
            #expect(lockedBefore)

            try await LoginAttemptService.clearFailures(username: "alice", on: app.db)
            let lockedAfter = try await LoginAttemptService.isLocked(
                username: "alice", now: now, windowSeconds: 900, threshold: 5, on: app.db)
            #expect(!lockedAfter)
        }
    }

    @Test func failuresExpireAfterWindow() async throws {
        try await withApp(app) { _ in
            let start = Date()
            let later = start.addingTimeInterval(901)
            for _ in 0..<5 {
                try await LoginAttemptService.recordFailure(
                    username: "alice", now: start, windowSeconds: 900, on: app.db)
            }
            let lockedLater = try await LoginAttemptService.isLocked(
                username: "alice", now: later, windowSeconds: 900, threshold: 5, on: app.db)
            #expect(!lockedLater)
        }
    }
}

// MARK: - Cross-instance sharing (#1154 acceptance)

/// Two Application instances backed by ONE SQLite file — the multi-process
/// deployment shape. Failure counts and rate windows recorded through one
/// instance must be visible to the other.
@Suite(.serialized) struct LoginRateLimitCrossInstanceTests {

    @Test func lockoutAccumulatesAcrossInstances() async throws {
        try await withTwoAppsOnSharedDatabase { appA, appB in
            let now = Date()
            // Three failures land on instance A, two on instance B.
            for _ in 0..<3 {
                try await LoginAttemptService.recordFailure(
                    username: "mallory", now: now, windowSeconds: 900, on: appA.db)
            }
            for _ in 0..<2 {
                try await LoginAttemptService.recordFailure(
                    username: "mallory", now: now, windowSeconds: 900, on: appB.db)
            }
            // Either instance must see the combined total and lock.
            let lockedOnA = try await LoginAttemptService.isLocked(
                username: "mallory", now: now, windowSeconds: 900, threshold: 5, on: appA.db)
            let lockedOnB = try await LoginAttemptService.isLocked(
                username: "mallory", now: now, windowSeconds: 900, threshold: 5, on: appB.db)
            #expect(lockedOnA)
            #expect(lockedOnB)
        }
    }

    @Test func ipWindowIsSharedAcrossInstances() async throws {
        try await withTwoAppsOnSharedDatabase { appA, appB in
            let now = Date()
            // Cap of 3: two requests via A, one via B — the fourth (via B)
            // must be rejected even though B only saw two locally.
            _ = try await LoginAttemptService.recordAndCheckIP(
                ip: "9.9.9.9", now: now, windowSeconds: 60, max: 3, on: appA.db)
            _ = try await LoginAttemptService.recordAndCheckIP(
                ip: "9.9.9.9", now: now, windowSeconds: 60, max: 3, on: appA.db)
            let third = try await LoginAttemptService.recordAndCheckIP(
                ip: "9.9.9.9", now: now, windowSeconds: 60, max: 3, on: appB.db)
            let fourth = try await LoginAttemptService.recordAndCheckIP(
                ip: "9.9.9.9", now: now, windowSeconds: 60, max: 3, on: appB.db)
            #expect(third)
            #expect(!fourth)
        }
    }
}

// MARK: - Shared-database two-app helper

/// Builds two bare Applications over one SQLite file (migrations run once)
/// and guarantees both are shut down. Used by the #1154 cross-instance
/// tests; lives here because this file hosts the first of them.
func withTwoAppsOnSharedDatabase(
    _ body: (Application, Application) async throws -> Void
) async throws {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("chickadee-shared-\(UUID().uuidString).sqlite").path

    func makeApp(migrate: Bool) async throws -> Application {
        try await makeTestingApplication { app in
            try configureDatabase(app, settings: .sqlite(path: dbPath))
            registerMigrations(on: app)
            if migrate {
                let priorLogLevel = app.logger.logLevel
                app.logger.logLevel = .warning
                try await app.autoMigrate()
                app.logger.logLevel = priorLogLevel
            }
        }
    }

    let appA = try await makeApp(migrate: true)
    let appB: Application
    do {
        appB = try await makeApp(migrate: false)
    } catch {
        try? await appA.asyncShutdown()
        throw error
    }

    do {
        try await body(appA, appB)
    } catch {
        try? await appA.asyncShutdown()
        try? await appB.asyncShutdown()
        try? FileManager.default.removeItem(atPath: dbPath)
        throw error
    }
    try await appA.asyncShutdown()
    try await appB.asyncShutdown()
    try? FileManager.default.removeItem(atPath: dbPath)
}
