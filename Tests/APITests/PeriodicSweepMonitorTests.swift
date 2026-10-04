// Tests/APITests/PeriodicSweepMonitorTests.swift
//
// `PeriodicSweepMonitor.stop()` waits for the sweep it started (#1922).
// Before, it cancelled the loop and returned at once, so a sweep running at
// shutdown kept querying `application.db` while Fluent closed it: the #1700
// shape. The separate boot sweep is gone (#2054, audit A16): the loop's first
// iteration is the sweep at start, so a boot runs each sweep once.

import ChickadeeTestSupport
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.timeLimit(.minutes(1))) struct PeriodicSweepMonitorTests {

    /// Counts sweeps that began and sweeps that ended.
    private actor SweepProbe {
        private(set) var started = 0
        private(set) var finished = 0
        func begin() { started += 1 }
        func end() { finished += 1 }
    }

    /// A monitor whose sweep waits 300 ms in a way that ignores cancellation,
    /// as a database query in flight does.
    private static func monitor(probe: SweepProbe) -> PeriodicSweepMonitor {
        PeriodicSweepMonitor(name: "probe", interval: 3600) { _ in
            await probe.begin()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
                    continuation.resume()
                }
            }
            await probe.end()
        }
    }

    private static func waitForFirstSweep(_ probe: SweepProbe) async throws {
        for _ in 0..<200 {
            if await probe.started > 0 { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw IssueRecorded("the monitor never started a sweep")
    }

    @Test func stopReturnsOnlyAfterTheRunningSweepHasEnded() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let probe = SweepProbe()
            let monitor = Self.monitor(probe: probe)
            monitor.start(application: app)
            try await Self.waitForFirstSweep(probe)

            await monitor.stop()

            #expect(await probe.finished == probe.started)
        }
    }

    @Test func stopBeforeStartReturnsAtOnce() async {
        let monitor = Self.monitor(probe: SweepProbe())
        await monitor.stop()
        await monitor.stop()
    }
}
