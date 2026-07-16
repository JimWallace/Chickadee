// Tests/APITests/SweepLeaseCoordinatorTests.swift
//
// #1155: leader election for periodic sweeps. The property that matters is
// cross-instance: with two Applications on one database, exactly one holds a
// given sweep's lease at a time, renewal keeps it, and an expired lease
// hands off.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class SweepLeaseCoordinatorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-lease")
    }

    @Test func firstClaimWinsAndRenewalKeepsIt() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let first = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-a", holder: "proc-1", ttlSeconds: 120, now: now, on: app.db)
            #expect(first)

            // Renewal by the same holder succeeds and extends the expiry.
            let renewed = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-a", holder: "proc-1", ttlSeconds: 120,
                now: now.addingTimeInterval(60), on: app.db)
            #expect(renewed)
            let row = try #require(try await SweepLease.find("sweep-a", on: app.db))
            #expect(row.expiresAt > now.addingTimeInterval(150))
        }
    }

    @Test func secondHolderIsDeniedWhileLeaseIsLive() async throws {
        try await withApp(app) { _ in
            let now = Date()
            _ = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-b", holder: "proc-1", ttlSeconds: 120, now: now, on: app.db)
            let rival = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-b", holder: "proc-2", ttlSeconds: 120,
                now: now.addingTimeInterval(30), on: app.db)
            #expect(!rival)

            let row = try #require(try await SweepLease.find("sweep-b", on: app.db))
            #expect(row.holder == "proc-1")
        }
    }

    @Test func expiredLeaseIsTakenOver() async throws {
        try await withApp(app) { _ in
            let now = Date()
            _ = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-c", holder: "proc-1", ttlSeconds: 60, now: now, on: app.db)

            // proc-1 stops renewing; past the TTL, proc-2 takes over.
            let takeover = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-c", holder: "proc-2", ttlSeconds: 60,
                now: now.addingTimeInterval(61), on: app.db)
            #expect(takeover)

            let row = try #require(try await SweepLease.find("sweep-c", on: app.db))
            #expect(row.holder == "proc-2")
        }
    }

    @Test func leasesAreIndependentPerSweepName() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let a = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-d", holder: "proc-1", ttlSeconds: 120, now: now, on: app.db)
            let b = try await SweepLeaseCoordinator.acquireOrRenew(
                name: "sweep-e", holder: "proc-2", ttlSeconds: 120, now: now, on: app.db)
            #expect(a)
            #expect(b)
        }
    }

    /// The #1155 acceptance property: with two Application instances on one
    /// shared database, each sweep runs on exactly one of them, and
    /// leadership fails over when the holder stops renewing.
    @Test func exactlyOneInstanceHoldsEachLeaseAcrossProcesses() async throws {
        try await withApp(app) { _ in
            try await withTwoAppsOnSharedDatabase { appA, appB in
                let now = Date()
                let holderA = appA.sweepLeaseHolderID
                let holderB = appB.sweepLeaseHolderID
                #expect(holderA != holderB)

                let aWins = try await SweepLeaseCoordinator.acquireOrRenew(
                    name: "Session reaper", holder: holderA, ttlSeconds: 120,
                    now: now, on: appA.db)
                let bDenied = try await SweepLeaseCoordinator.acquireOrRenew(
                    name: "Session reaper", holder: holderB, ttlSeconds: 120,
                    now: now.addingTimeInterval(1), on: appB.db)
                #expect(aWins)
                #expect(!bDenied)

                // A keeps renewing → B stays out.
                let aRenews = try await SweepLeaseCoordinator.acquireOrRenew(
                    name: "Session reaper", holder: holderA, ttlSeconds: 120,
                    now: now.addingTimeInterval(60), on: appA.db)
                let bStillDenied = try await SweepLeaseCoordinator.acquireOrRenew(
                    name: "Session reaper", holder: holderB, ttlSeconds: 120,
                    now: now.addingTimeInterval(61), on: appB.db)
                #expect(aRenews)
                #expect(!bStillDenied)

                // A crashes (stops renewing) → B takes over after the TTL.
                let bTakesOver = try await SweepLeaseCoordinator.acquireOrRenew(
                    name: "Session reaper", holder: holderB, ttlSeconds: 120,
                    now: now.addingTimeInterval(200), on: appB.db)
                #expect(bTakesOver)
            }
        }
    }
}
