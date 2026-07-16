// Tests/APITests/WorkerNonceReplayGuardTests.swift
//
// #1154: worker-HMAC replay protection moved from a per-process actor to the
// worker_nonces table. The property that matters is cross-instance: a nonce
// consumed through one Application must be rejected by another sharing the
// same database — the old in-memory store silently voided this behind a
// load balancer.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class WorkerNonceReplayGuardTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-nonce")
    }

    @Test func firstUseInsertsAndReplayIsRejected() async throws {
        try await withApp(app) { _ in
            let expiry = Date().addingTimeInterval(300)
            let first = try await WorkerNonceReplayGuard.insertIfNew(
                nonceKey: "w1:nonce-a", expiresAt: expiry, on: app.db)
            #expect(first)

            let replay = try await WorkerNonceReplayGuard.insertIfNew(
                nonceKey: "w1:nonce-a", expiresAt: expiry, on: app.db)
            #expect(!replay)

            // A different worker using the same raw nonce is a different key.
            let otherWorker = try await WorkerNonceReplayGuard.insertIfNew(
                nonceKey: "w2:nonce-a", expiresAt: expiry, on: app.db)
            #expect(otherWorker)
        }
    }

    @Test func purgeDropsExpiredRowsOnly() async throws {
        try await withApp(app) { _ in
            _ = try await WorkerNonceReplayGuard.insertIfNew(
                nonceKey: "w1:expired", expiresAt: Date().addingTimeInterval(-10), on: app.db)
            _ = try await WorkerNonceReplayGuard.insertIfNew(
                nonceKey: "w1:live", expiresAt: Date().addingTimeInterval(300), on: app.db)

            await WorkerNonceReplayGuard.purgeExpiredIfDue(
                application: app, db: app.db, logger: app.logger)

            let remaining = try await WorkerNonce.query(on: app.db).all()
            #expect(remaining.map(\.id) == ["w1:live"])
        }
    }

    @Test func purgeIsThrottledPerProcess() async throws {
        try await withApp(app) { _ in
            // First call consumes the throttle slot…
            await WorkerNonceReplayGuard.purgeExpiredIfDue(
                application: app, db: app.db, logger: app.logger)

            // …so an expired row inserted now survives the second call.
            _ = try await WorkerNonceReplayGuard.insertIfNew(
                nonceKey: "w1:stale", expiresAt: Date().addingTimeInterval(-10), on: app.db)
            await WorkerNonceReplayGuard.purgeExpiredIfDue(
                application: app, db: app.db, logger: app.logger)

            let count = try await WorkerNonce.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    /// The #1154 acceptance property: replay across processes is rejected.
    /// (Wrapped in withApp so the suite's own init-created app is shut down —
    /// every test in a class suite must consume `app` or Linux SIGILLs on
    /// the un-shutdown Application's deinit.)
    @Test func nonceConsumedOnOneInstanceIsRejectedOnAnother() async throws {
        try await withApp(app) { _ in
            try await withTwoAppsOnSharedDatabase { appA, appB in
                let expiry = Date().addingTimeInterval(300)
                let first = try await WorkerNonceReplayGuard.insertIfNew(
                    nonceKey: "w1:cross", expiresAt: expiry, on: appA.db)
                #expect(first)

                let replayOnOtherInstance = try await WorkerNonceReplayGuard.insertIfNew(
                    nonceKey: "w1:cross", expiresAt: expiry, on: appB.db)
                #expect(!replayOnOtherInstance)
            }
        }
    }
}
