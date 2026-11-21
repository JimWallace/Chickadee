// Tests/APITests/Infrastructure/PeriodicSweepMonitorLeaseTests.swift
//
// The leased tick of `PeriodicSweepMonitor` (#1155) and its lifecycle
// handler. `PeriodicSweepMonitorTests` covers the wait at `stop()`; this
// suite covers what one tick does when this instance does not hold the
// lease, when the lease check itself fails, and when the sweep throws. Each
// tick test awaits `sweepOnce`, which runs the same leased tick as the loop.

import ChickadeeTestSupport
import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import Vapor

@testable import APIServer

// MARK: - Log capture

/// Keeps every log line at every level, with its level.
private final class SweepLeaseLogCapture: Sendable {
    private let stored = Mutex<[(level: Logger.Level, message: String)]>([])

    var logger: Logger {
        Logger(label: "sweep-lease-log-capture.test") { _ in SweepLeaseLogHandler(sink: self) }
    }

    fileprivate func append(_ level: Logger.Level, _ message: String) {
        stored.withLock { $0.append((level, message)) }
    }

    func messages(at level: Logger.Level, containing fragment: String) -> [String] {
        stored.withLock { lines in
            lines.filter { $0.level == level && $0.message.contains(fragment) }.map(\.message)
        }
    }

    func messages(containing fragment: String) -> [String] {
        stored.withLock { lines in lines.filter { $0.message.contains(fragment) }.map(\.message) }
    }
}

private struct SweepLeaseLogHandler: LogHandler {
    let sink: SweepLeaseLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        sink.append(event.level, event.message.description)
    }
}

/// Counts the sweeps that ran.
private actor SweepLeaseRunCounter {
    private(set) var runs = 0
    func record() { runs += 1 }
}

private struct SweepLeaseProbeError: Error, LocalizedError {
    var errorDescription: String? { "probe sweep exploded" }
}

// MARK: - Suite

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PeriodicSweepMonitorLeaseTests {

    /// Polls `condition` until it holds. A wait for the monitor's own task,
    /// not a sleep that lets time pass: the monitor sleeps an hour after its
    /// first tick, so there is exactly one tick to wait for.
    private static func waitUntil(
        _ what: String, _ condition: @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw IssueRecorded("timed out waiting until \(what)")
    }

    /// Another instance holds the lease: the tick logs at debug that it
    /// skipped, and the sweep body never runs.
    @Test func aTickWithoutTheLeaseSkipsTheSweep() async throws {
        try await withTestApp { app in
            let capture = SweepLeaseLogCapture()
            app.logger = capture.logger
            let name = "lease-gap-held-elsewhere"
            let heldByOther = try await SweepLeaseCoordinator.acquireOrRenew(
                name: name, holder: "another-instance", ttlSeconds: 3600, on: app.db)
            #expect(heldByOther)

            let counter = SweepLeaseRunCounter()
            let monitor = PeriodicSweepMonitor(name: name, interval: 3600) { _ in
                await counter.record()
            }
            #expect(try await monitor.acquireLease(application: app) == false)

            await monitor.sweepOnce(application: app)

            #expect(await counter.runs == 0)
            #expect(
                capture.messages(at: .debug, containing: "\(name) sweep skipped: another instance holds the lease")
                    .count == 1)
            let row = try #require(try await SweepLease.find(name, on: app.db))
            #expect(row.holder == "another-instance")
        }
    }

    /// The lease check fails (Postgres refuses a NUL byte in the key): the
    /// tick logs a warning and does not run the sweep. The error never
    /// escapes the tick.
    @Test func aFailedLeaseCheckLogsAWarningAndSkipsTheSweep() async throws {
        try await withTestApp { app in
            let capture = SweepLeaseLogCapture()
            app.logger = capture.logger
            let counter = SweepLeaseRunCounter()
            let monitor = PeriodicSweepMonitor(name: "lease-gap\u{0}nul", interval: 3600) { _ in
                await counter.record()
            }

            await monitor.sweepOnce(application: app)

            #expect(await counter.runs == 0)
            #expect(capture.messages(at: .warning, containing: "sweep lease check failed").count == 1)
            #expect(capture.messages(containing: "sweep failed").isEmpty)
        }
    }

    /// A sweep that throws is logged at error with the monitor's name and
    /// the error's description; the error never escapes the tick.
    @Test func aThrowingSweepIsLoggedAsAnError() async throws {
        try await withTestApp { app in
            let capture = SweepLeaseLogCapture()
            app.logger = capture.logger
            let counter = SweepLeaseRunCounter()
            let monitor = PeriodicSweepMonitor(name: "lease-gap-throws", interval: 3600) { _ in
                await counter.record()
                throw SweepLeaseProbeError()
            }

            await monitor.sweepOnce(application: app)

            #expect(await counter.runs == 1)
            #expect(
                capture.messages(at: .error, containing: "lease-gap-throws sweep failed: probe sweep exploded")
                    .count == 1)
        }
    }

    /// A sweep that stops at a cancellation check is not a failure: it logs
    /// nothing at error.
    @Test func aCancelledSweepIsNotLoggedAsAFailure() async throws {
        try await withTestApp { app in
            let capture = SweepLeaseLogCapture()
            app.logger = capture.logger
            let counter = SweepLeaseRunCounter()
            let monitor = PeriodicSweepMonitor(name: "lease-gap-cancelled", interval: 3600) { _ in
                await counter.record()
                throw CancellationError()
            }

            await monitor.sweepOnce(application: app)

            #expect(capture.messages(containing: "sweep failed").isEmpty)
            #expect(capture.messages(at: .error, containing: "lease-gap-cancelled").isEmpty)
        }
    }

    /// The lifecycle handler starts the monitor at boot (its first tick runs
    /// the sweep at once) and stops it at shutdown. A second boot hook call
    /// does not start a second loop.
    @Test func theLifecycleHandlerStartsAndStopsTheMonitor() async throws {
        try await withTestApp { app in
            let counter = SweepLeaseRunCounter()
            let monitor = PeriodicSweepMonitor(name: "lease-gap-lifecycle", interval: 3600) { _ in
                await counter.record()
            }
            let handler = PeriodicSweepLifecycleHandler { _ in monitor }

            try await handler.didBootAsync(app)
            try await handler.didBootAsync(app)
            try await Self.waitUntil("the boot sweep runs") { await counter.runs >= 1 }
            await handler.shutdownAsync(app)

            #expect(await counter.runs == 1)
            let row = try #require(try await SweepLease.find("lease-gap-lifecycle", on: app.db))
            #expect(row.holder == app.sweepLeaseHolderID)
        }
    }
}
