// Tests/APITests/DataExportDrainTests.swift
//
// The data-export manager owns its generation tasks (#1700). Before it did,
// a generation started by a request outlived the application: the first
// query after shutdown failed with `ConnectionPoolError.shutdown`, and the
// failure path then trapped in Fluent's `Application.db` accessor. These
// tests pin the two halves of the fix: `drain()` cancels and awaits every
// task, and the lifecycle handler runs that drain while the database is
// still open, which is the reverse-registration order Vapor guarantees.

import Fluent
import Foundation
import Synchronization
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class DataExportDrainTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dexp-drain")
    }

    @Test func drainCancelsAndAwaitsInFlightWork() async throws {
        try await withApp(app) { app in
            let manager = app.dataExportManager
            let finished = Mutex(false)

            let started = await manager.startWork(userID: UUID()) {
                // Long enough that only cancellation can end it in time.
                try? await Task.sleep(for: .seconds(30))
                finished.withLock { $0 = true }
            }
            #expect(started)
            #expect(await manager.inFlightCount == 1)

            await manager.drain()

            #expect(finished.withLock { $0 })
            #expect(await manager.inFlightCount == 0)
        }
    }

    @Test func aSecondStartForTheSameUserIsANoOpWhileTheFirstRuns() async throws {
        try await withApp(app) { app in
            let manager = app.dataExportManager
            let userID = UUID()
            let first = await manager.startWork(userID: userID) {
                try? await Task.sleep(for: .seconds(30))
            }
            let second = await manager.startWork(userID: userID) {}
            #expect(first)
            #expect(!second)
            #expect(await manager.inFlightCount == 1)
            await manager.drain()
            #expect(await manager.inFlightCount == 0)
        }
    }

    /// Once the drain has begun, a new export starts nothing: a task started
    /// then would outlive the drain (#2302).
    @Test func noWorkStartsAfterTheDrainBegins() async throws {
        try await withApp(app) { app in
            let manager = app.dataExportManager
            await manager.drain()
            let started = await manager.startWork(userID: UUID()) {}
            #expect(!started)
            #expect(await manager.inFlightCount == 0)
        }
    }

    @Test func shutdownDrainsWhileTheDatabaseIsStillOpen() async throws {
        let manager = app.dataExportManager
        let finished = Mutex(false)
        let databaseAnswered = Mutex(false)

        try await withApp(app) { app in
            await manager.startWork(userID: UUID()) {
                try? await Task.sleep(for: .seconds(30))
                // Runs inside the shutdown drain. Fluent's own handler was
                // registered earlier, so it shuts down later: a query here
                // must still be answered, not trapped on a cleared store.
                let answered = (try? await APIUser.query(on: app.db).count()) != nil
                databaseAnswered.withLock { $0 = answered }
                finished.withLock { $0 = true }
            }
        }

        // `withApp` has shut the app down. Without the lifecycle handler the
        // task would still be sleeping here and both flags would be false.
        #expect(finished.withLock { $0 })
        #expect(databaseAnswered.withLock { $0 })
        #expect(await manager.inFlightCount == 0)
    }
}

/// Guard for the production wiring itself.
///
/// A struct suite deliberately — it owns no Vapor app, so it can assert against
/// the production bootstrap without the class-suite `withApp` shutdown dance.
@Suite struct DataExportDrainWiringTests {

    /// The test app registers the drain explicitly (see `makeTestApp`), so
    /// nothing else would notice if the production registration were dropped
    /// — and dropped, it means a generation task can outlive the application
    /// again on every deploy cutover.
    @Test func productionBootstrapRegistersTheDrain() throws {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }  // -> repo root
        let source = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/APIServer/Bootstrap/AppServices.swift"),
            encoding: .utf8)
        #expect(source.contains("DataExportDrainLifecycleHandler()"))
    }
}
