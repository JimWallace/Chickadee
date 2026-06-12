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

import Vapor

final class PeriodicSweepMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let name: String
    private let intervalNanoseconds: UInt64
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
        intervalNanoseconds = UInt64(max(interval, minimumInterval) * 1_000_000_000)
        self.runImmediately = runImmediately
        self.sweep = sweep
    }

    func start(application: Application) {
        guard task == nil else { return }
        if runImmediately {
            // Best-effort boot sweep, detached from the periodic loop, so a
            // restart after a long quiet period doesn't have to wait for the
            // loop to come up to reclaim space.
            let sweep = sweep
            let name = name
            Task {
                do {
                    try await sweep(application)
                } catch {
                    application.logger.error(
                        "Initial \(name) sweep failed: \(error.localizedDescription)"
                    )
                }
            }
        }
        task = Task { [sweep, name, intervalNanoseconds] in
            while !Task.isCancelled {
                do {
                    try await sweep(application)
                } catch {
                    application.logger.error(
                        "\(name) sweep failed: \(error.localizedDescription)"
                    )
                }
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
