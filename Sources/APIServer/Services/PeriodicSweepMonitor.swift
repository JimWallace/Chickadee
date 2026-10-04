// APIServer/Services/PeriodicSweepMonitor.swift
//
// Shared scaffolding for the periodic background services (June 2026 audit,
// item 6).  Every "sweep on a timer" service — session reaper, stuck-submission
// reaper, MCP OAuth reaper, audit-log reaper, assignment deadline sweep,
// class-goal achievement sweep, server health alerts — used to hand-roll the
// same ~85-line Monitor + StorageKey + LifecycleHandler pattern.  Each service
// file now keeps only its domain sweep function, its StorageKey, and an
// `Application` accessor that builds one of these.
//
// Behavior contract (identical to the hand-rolled monitors it replaced):
//   • The loop runs the sweep first, then sleeps `interval` — so the first
//     periodic sweep happens immediately at start, not one interval later.
//   • `runImmediately` additionally fires one detached best-effort sweep at
//     start (the historical `didBoot` boot sweep), so a restart after a long
//     quiet period reclaims space right away even if the loop's first
//     iteration is slow to schedule.
//   • Sweep errors are logged via `application.logger.error` with the
//     monitor's name and never escape the loop. A sweep that stops at a
//     cancellation check is not a failure and is not logged as one.
//   • `stop()` cancels the loop and the boot sweep and WAITS for both to end
//     (#1922), so no sweep is still using `application.db` when Fluent closes
//     it. A sweep body ends at its next cancellation check, or when its
//     current query returns.
//
// Multi-process (#1155): every process runs every loop, but each tick first
// claims/renews a DB leader lease keyed on the monitor's name
// (SweepLeaseCoordinator) and only the lease holder executes the sweep body.
// Without this, N instances behind a load balancer ran every sweep N times —
// duplicate BrightSpace pushes to LEARN, doubled health alerts, racing
// reapers. The lease TTL is 2× the interval (min 2 min), so a crashed
// leader's sweeps resume on another instance within roughly one missed
// cycle. Single-process deployments always hold the lease; the tick cost is
// one small UPDATE + SELECT.

import Synchronization
import Vapor

final class PeriodicSweepMonitor: Sendable {
    /// The tasks this monitor started and must wait for at `stop()`.
    private struct Running {
        var loop: Task<Void, Never>?
        var boot: Task<Void, Never>?
    }

    private let running = Mutex(Running())
    /// The lease key and the name in log lines.
    let name: String
    private let intervalNanoseconds: UInt64
    private let leaseTTLSeconds: TimeInterval
    private let runImmediately: Bool
    private let sweep: @Sendable (Application) async throws -> Void

    /// - Parameters:
    ///   - name: Human-readable service name used in error log messages
    ///     ("<name> sweep failed: …").
    ///   - interval: Seconds between sweeps, clamped to `minimumInterval`.
    ///   - minimumInterval: Lower bound on `interval` — per-service (the
    ///     hourly reapers clamp at 60 s, the minute-cadence sweeps at 1 s).
    ///   - runImmediately: Fire one extra detached best-effort sweep at
    ///     start, ahead of the periodic loop.
    ///   - sweep: The domain logic. Thrown errors are logged, never rethrown.
    init(
        name: String,
        interval: TimeInterval,
        minimumInterval: TimeInterval = 60,
        runImmediately: Bool,
        sweep: @escaping @Sendable (Application) async throws -> Void
    ) {
        self.name = name
        let effectiveInterval = max(interval, minimumInterval)
        intervalNanoseconds = UInt64(effectiveInterval * 1_000_000_000)
        leaseTTLSeconds = max(effectiveInterval * 2, 120)
        self.runImmediately = runImmediately
        self.sweep = sweep
    }

    /// Claims or renews this monitor's leader lease, as each tick does, and
    /// returns whether this instance holds it. For work outside the loop that
    /// must run on the leader only: the manual BrightSpace "Sync now" sweep
    /// used to run on any instance, beside the leader's sweep (#1923).
    func acquireLease(application: Application) async throws -> Bool {
        try await SweepLeaseCoordinator.acquireOrRenew(
            name: name,
            holder: application.sweepLeaseHolderID,
            ttlSeconds: leaseTTLSeconds,
            on: application.db
        )
    }

    /// One leased tick: claim/renew the leader lease, then run the sweep
    /// body only as the holder. Lease errors and sweep errors are both
    /// logged and never escape (matching the pre-lease behavior contract).
    private func runLeasedSweep(application: Application, context: String) async {
        let isLeader: Bool
        do {
            isLeader = try await acquireLease(application: application)
        } catch {
            application.logger.warning(
                "\(context)\(name) sweep lease check failed: \(error.localizedDescription)"
            )
            return
        }
        guard isLeader else {
            application.logger.debug(
                "\(context)\(name) sweep skipped: another instance holds the lease"
            )
            return
        }
        do {
            try await sweep(application)
        } catch is CancellationError {
            // Stopped at shutdown, between units of work: not a failure.
        } catch {
            application.logger.error(
                "\(context)\(name) sweep failed: \(error.localizedDescription)"
            )
        }
    }

    func start(application: Application) {
        running.withLock { running in
            guard running.loop == nil else { return }
            if runImmediately {
                // Best-effort boot sweep, separate from the periodic loop, so
                // a restart after a long quiet period doesn't have to wait for
                // the loop to come up to reclaim space.
                running.boot = Task {
                    await self.runLeasedSweep(application: application, context: "Initial ")
                }
            }
            running.loop = Task { [intervalNanoseconds] in
                while !Task.isCancelled {
                    await self.runLeasedSweep(application: application, context: "")
                    do {
                        try await Task.sleep(nanoseconds: intervalNanoseconds)
                    } catch {
                        break
                    }
                }
            }
        }
    }

    /// Cancels the loop and the boot sweep, and returns when both have ended.
    func stop() async {
        let tasks = running.withLock { running in
            defer { running = Running() }
            return [running.loop, running.boot].compactMap { $0 }
        }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }
}

/// Generic lifecycle registration for a `PeriodicSweepMonitor`: didBoot
/// starts the monitor returned by `monitor`, shutdown stops it and waits for
/// it.  Services whose boot needs extra gating (e.g. the health-alert enabled
/// check) keep their own handler.
///
/// Vapor runs `shutdownAsync` handlers in reverse registration order, and
/// `bootstrapAppServices` registers these after Fluent, so the wait happens
/// while `application.db` is still open (the #1700 shape).
struct PeriodicSweepLifecycleHandler: LifecycleHandler {
    private let monitor: @Sendable (Application) -> PeriodicSweepMonitor

    init(monitor: @escaping @Sendable (Application) -> PeriodicSweepMonitor) {
        self.monitor = monitor
    }

    func didBoot(_ application: Application) throws {
        monitor(application).start(application: application)
    }

    func shutdownAsync(_ application: Application) async {
        await monitor(application).stop()
    }
}
