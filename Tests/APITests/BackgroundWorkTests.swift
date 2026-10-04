// Tests/APITests/BackgroundWorkTests.swift
//
// `Application.backgroundWork` owns the work the server starts and does not
// wait for (#1923): a "Sync now" grade push, logout token revocation, and OIDC
// discovery at boot. Each was a bare `Task` that could outlive the
// application, and the grade push uses the database. These tests pin the
// owner, the shutdown order, and the two guards that stop a manual grade-sync
// sweep from running beside the periodic one.

import Fluent
import Foundation
import Synchronization
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(1))) struct BackgroundWorkTests {

    @Test func drainCancelsAndAwaitsRunningWork() async {
        let work = BackgroundWork()
        let finished = Mutex(false)

        let started = await work.start {
            // Long enough that only cancellation can end it in time.
            try? await Task.sleep(for: .seconds(30))
            finished.withLock { $0 = true }
        }
        #expect(started)
        #expect(await work.runningCount == 1)

        await work.drain()

        #expect(finished.withLock { $0 })
        #expect(await work.runningCount == 0)
    }

    @Test func workThatEndsIsForgotten() async {
        let work = BackgroundWork()
        await work.start {}
        while await work.runningCount > 0 {
            await Task.yield()
        }
        #expect(await work.runningCount == 0)
    }

    /// Work started after the drain began would outlive the drain.
    @Test func nothingStartsOnceTheDrainHasBegun() async {
        let work = BackgroundWork()
        await work.drain()
        let ran = Mutex(false)

        let started = await work.start { ran.withLock { $0 = true } }

        #expect(!started)
        #expect(await work.runningCount == 0)
        #expect(!ran.withLock { $0 })
    }
}

@Suite(.timeLimit(.minutes(1))) struct BrightSpaceGradeSyncSlotTests {

    @Test func aSweepDoesNotRunWhileAnotherHoldsTheSlot() async {
        let slot = BrightSpaceGradeSyncSlot()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()

        let first = Task {
            await slot.runIfFree { () async -> Int in
                enteredContinuation.yield()
                for await _ in release {}
                return 1
            }
        }
        for await _ in entered { break }

        let second = await slot.runIfFree { () async -> Int in 2 }
        #expect(second == nil)

        releaseContinuation.finish()
        #expect(await first.value == 1)
        #expect(await slot.runIfFree { () async -> Int in 3 } == 3)
    }

    @Test func aSweepThatThrowsFreesTheSlot() async {
        struct SweepFailed: Error {}
        let slot = BrightSpaceGradeSyncSlot()

        await #expect(throws: SweepFailed.self) {
            try await slot.runIfFree { () async throws -> Int in throw SweepFailed() }
        }

        #expect(await slot.runIfFree { () async -> Int in 1 } == 1)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) final class BackgroundWorkShutdownTests {

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-background-work")
        // The test app does not run `bootstrapAppServices`. Register the drain
        // here, after Fluent's handler, which is the production order.
        app.lifecycle.use(BackgroundWorkDrainLifecycleHandler())
    }

    @Test func shutdownDrainsWhileTheDatabaseIsStillOpen() async throws {
        let work = app.backgroundWork
        let finished = Mutex(false)
        let databaseAnswered = Mutex(false)

        try await withApp(app) { app in
            await work.start {
                try? await Task.sleep(for: .seconds(30))
                // Runs inside the shutdown drain. Fluent shuts down after it,
                // so this query must still be answered.
                let answered = (try? await APIUser.query(on: app.db).count()) != nil
                databaseAnswered.withLock { $0 = answered }
                finished.withLock { $0 = true }
            }
        }

        // `withApp` has shut the app down. Without the drain the task would
        // still be sleeping here, and both flags would be false.
        #expect(finished.withLock { $0 })
        #expect(databaseAnswered.withLock { $0 })
        #expect(await work.runningCount == 0)
    }

    @Test func aManualSweepDoesNotRunOnAnotherInstancesLease() async throws {
        try await withApp(app) { app in
            try await SweepLease(
                name: app.brightSpaceGradeSyncMonitor.name,
                holder: "another-instance",
                expiresAt: Date().addingTimeInterval(600)
            ).create(on: app.db)
            let ran = Mutex(false)

            await runManualBrightSpaceSweep(app) {
                ran.withLock { $0 = true }
                return 0
            }

            #expect(!ran.withLock { $0 })
        }
    }

    @Test func aManualSweepRunsWhenThisInstanceCanHoldTheLease() async throws {
        try await withApp(app) { app in
            let ran = Mutex(false)

            await runManualBrightSpaceSweep(app) {
                ran.withLock { $0 = true }
                return 0
            }

            #expect(ran.withLock { $0 })
            let lease = try await SweepLease.find(app.brightSpaceGradeSyncMonitor.name, on: app.db)
            #expect(lease?.holder == app.sweepLeaseHolderID)
        }
    }

    /// The lease cannot separate two sweeps of one instance, so the slot does.
    @Test func aManualSweepDoesNotRunWhileThePeriodicSweepHoldsTheSlot() async throws {
        try await withApp(app) { app in
            let slot = app.brightSpaceGradeSyncSlot
            let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
            let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
            let periodic = Task {
                await slot.runIfFree { () async -> Int in
                    enteredContinuation.yield()
                    for await _ in release {}
                    return 0
                }
            }
            for await _ in entered { break }
            let ran = Mutex(false)

            await runManualBrightSpaceSweep(app) {
                ran.withLock { $0 = true }
                return 0
            }

            #expect(!ran.withLock { $0 })
            releaseContinuation.finish()
            _ = await periodic.value
        }
    }
}

/// Guards for the production wiring. The test app does not run
/// `bootstrapAppServices`, so nothing else would notice if it were dropped.
@Suite struct BackgroundWorkWiringTests {

    @Test func productionBootstrapCreatesTheOwnerAndTheSlotAndRegistersTheDrain() throws {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }  // -> repo root
        let source = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/APIServer/Bootstrap/AppServices.swift"),
            encoding: .utf8)
        #expect(source.contains("app.backgroundWork = BackgroundWork()"))
        #expect(source.contains("BackgroundWorkDrainLifecycleHandler()"))
        #expect(source.contains("app.brightSpaceGradeSyncSlot = BrightSpaceGradeSyncSlot()"))
    }
}
