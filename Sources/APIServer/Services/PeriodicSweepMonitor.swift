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
//     monitor's name and never escape the loop.
//   • Cancellation (via `stop()`) ends the loop at the next sleep.
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

import Vapor

final class PeriodicSweepMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let name: String
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

    /// One leased tick: claim/renew the leader lease, then run the sweep
    /// body only as the holder. Lease errors and sweep errors are both
    /// logged and never escape (matching the pre-lease behavior contract).
    private func runLeasedSweep(application: Application, context: String) async {
        let isLeader: Bool
        do {
            isLeader = try await SweepLeaseCoordinator.acquireOrRenew(
                name: name,
                holder: application.sweepLeaseHolderID,
                ttlSeconds: leaseTTLSeconds,
                on: application.db
            )
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
        } catch {
            application.logger.error(
                "\(context)\(name) sweep failed: \(error.localizedDescription)"
            )
        }
    }

    func start(application: Application) {
        guard task == nil else { return }
        if runImmediately {
            // Best-effort boot sweep, detached from the periodic loop, so a
            // restart after a long quiet period doesn't have to wait for the
            // loop to come up to reclaim space.
            Task {
                await self.runLeasedSweep(application: application, context: "Initial ")
            }
        }
        task = Task { [intervalNanoseconds] in
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

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Generic lifecycle registration for a `PeriodicSweepMonitor`: didBoot
/// starts the monitor returned by `monitor`, shutdown stops it.  Services
/// whose boot needs extra gating (e.g. the health-alert enabled check) keep
/// their own handler.
struct PeriodicSweepLifecycleHandler: LifecycleHandler {
    private let monitor: @Sendable (Application) -> PeriodicSweepMonitor

    init(monitor: @escaping @Sendable (Application) -> PeriodicSweepMonitor) {
        self.monitor = monitor
    }

    func didBoot(_ application: Application) throws {
        monitor(application).start(application: application)
    }

    func shutdown(_ application: Application) {
        monitor(application).stop()
    }
}
