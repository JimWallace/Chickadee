// Tests/APITests/TransientDatabaseLockRetryTests.swift
//
// The one retry for a transient SQLite lock (#1926). Worker claims and the
// attempt-number transaction used to decide "is this a lock?" with two
// different classifiers; they now share `isTransientDatabaseLockError` and
// keep their own attempt count and backoff.

import Testing
import Vapor

@testable import APIServer

@Suite struct TransientDatabaseLockRetryTests {

    /// An error that reads like a wrapped SQLite lock.
    private struct WrappedLockError: Error, CustomStringConvertible {
        let description: String
    }

    private struct UnrelatedError: Error {}

    @Test(arguments: [
        "database is locked", "busy: database is locked", "database table is locked",
        "SQLITE_BUSY_SNAPSHOT", "SQLITE_LOCKED", "the database is busy",
    ])
    func everyLockSpellingEitherOldClassifierAcceptedIsALock(text: String) {
        #expect(isTransientDatabaseLockError(WrappedLockError(description: text)))
    }

    @Test func anUnrelatedErrorIsNotALock() {
        #expect(!isTransientDatabaseLockError(UnrelatedError()))
        #expect(!isTransientDatabaseLockError(Abort(.conflict, reason: "already claimed")))
    }

    @Test func aLockIsRetriedUntilItSucceeds() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            var attempts = 0
            let value = try await withTransientDatabaseLockRetry(
                on: app.db, maxAttempts: 3, backoff: .fixed(.zero)
            ) {
                attempts += 1
                if attempts < 3 { throw WrappedLockError(description: "database is locked") }
                return "claimed"
            }
            #expect(value == "claimed")
            #expect(attempts == 3)
        }
    }

    @Test func eachBackoffWaitsAsItSays() {
        let doubling = LockRetryBackoff.doubling(from: .milliseconds(10))
        #expect((1...5).map(doubling.wait(afterAttempt:)) == [10, 20, 40, 80, 160].map { .milliseconds($0) })
        let fixed = LockRetryBackoff.fixed(.milliseconds(20))
        #expect((1...3).map(fixed.wait(afterAttempt:)) == Array(repeating: .milliseconds(20), count: 3))
    }

    @Test func anUnrelatedErrorIsThrownAtOnce() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            var attempts = 0
            await #expect(throws: UnrelatedError.self) {
                try await withTransientDatabaseLockRetry(on: app.db, backoff: .fixed(.zero)) {
                    attempts += 1
                    throw UnrelatedError()
                }
            }
            #expect(attempts == 1)
        }
    }

    @Test func theLastLockIsThrownWhenTheAttemptsRunOut() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            var attempts = 0
            await #expect(throws: WrappedLockError.self) {
                try await withTransientDatabaseLockRetry(on: app.db, maxAttempts: 4, backoff: .fixed(.zero)) {
                    attempts += 1
                    throw WrappedLockError(description: "database is locked")
                }
            }
            #expect(attempts == 4)
        }
    }

    /// The default doubles from 10 ms, as the attempt-number retry always did.
    @Test func theDefaultBackoffDoublesFromTenMilliseconds() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            var attempts = 0
            let started = ContinuousClock.now
            _ = try await withTransientDatabaseLockRetry(on: app.db, maxAttempts: 3) {
                attempts += 1
                if attempts < 3 { throw WrappedLockError(description: "database is locked") }
                return 0
            }
            // 10 ms + 20 ms of waiting at least.
            #expect(ContinuousClock.now - started >= .milliseconds(30))
        }
    }
}
