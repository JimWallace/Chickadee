// Tests/TestSupport/StarvationRecorder.swift
//
// In-job evidence for ci-flakiness Family 5: `api-tests` running at 3-5x its
// normal cost and, often enough, being killed at the job ceiling as
// `cancelled`.
//
// WHY THIS EXISTS, AND WHY IT IS NOT THE WEDGE WATCHDOG
//
// `WedgeWatchdog` measures SILENCE. Its own header says so, and says why a
// Family 5 lane can never trip it: a job running at 10x cost is still starting
// and finishing tests, so it resets the stall clock continuously. That is
// correct and must stay that way — a starved-but-progressing job has to remain
// a slow pass, and a wedged one has to become a fast failure. The consequence
// is that Family 5 had NO instrument at all: both incidents were diagnosed by
// hand from the tail of a log, which only works when somebody happens to look.
// This recorder is the missing half. It measures SLOWNESS, and specifically it
// measures WHOSE slowness.
//
// THE ONE QUESTION IT ANSWERS
//
// Family 5's open question is not "was it slow" — the job duration already
// says that. It is: did the machine stop giving us CPU (a hosted-runner
// problem we can only absorb), or did we saturate our own container (ours to
// fix)? Those look identical from the outside and the counters below separate
// them directly:
//
//   * `steal` from /proc/stat is time the HYPERVISOR gave to another VM. It is
//     the only first-party measurement of a neighbour on the physical host;
//     PSI and load average cannot see outside this VM at all. Steal high =>
//     not our fault, and nothing in this repository can fix it.
//   * `throttled` from the cgroup's `cpu.stat` is the kernel stopping us on
//     purpose for exceeding a quota. Rising => we are over our allowance.
//   * `self cpu` against `busy` says which share of the machine's busy time is
//     ours. A box that is saturated with somebody else's work is a neighbour;
//     a box saturated with OUR work is not a fault at all, which is why that
//     case gets no hint — see `PressureWindow.hint()`.
//   * PSI `io_full` / `mem_full` say the machine got NO work done because it
//     was waiting on disk or reclaiming memory — the two ways a job can crawl
//     with plenty of idle CPU. This is the one that fires today: APITests
//     spends 20-27 % of its wall clock there.
//   * `kids` / `thr` / `procs` are the self-saturation shape: APITests spawns
//     real interpreters (python3, Rscript, lua, octave-cli, racket, g++) from
//     25 of its files, so a subprocess storm is a live hypothesis and a
//     process census is what confirms or kills it.
//   * `scopes/min` is the THROUGHPUT half, taken from
//     `WedgeWatchdog.completedTrackedScopes` — finished test bodies. Without
//     it every reading above is an unanchored number; with it, one line says
//     both that throughput collapsed and what the machine was doing while it
//     did.
//
// If every one of those is flat while `scopes/min` is a third of normal, the
// answer is neither — the loss is inside our own process, and that is a
// different and much more interesting bug.
//
// WHY IT PRINTS PERIODICALLY RATHER THAN SUMMARISING AT EXIT
//
// The failure being investigated ENDS IN A KILL. GitHub tears the job down at
// `timeout-minutes` and the process never runs an exit handler, which is
// exactly why the only evidence either incident left behind was whatever had
// already reached the log. So this writes a line every 30 seconds, and every
// line carries BOTH the last window and the cumulative totals since arming —
// whatever the last line to survive is, it is also the summary. A healthy
// 5-minute `api-tests` pays about ten lines for that.
//
// Arming is deliberately not a new seam: `WedgeWatchdog` already arms on the
// one universal scope in both test targets (`withApp` in APITests, helper
// scopes in WorkerTests) and is guarded against losing that arming, so the
// recorder starts with the watchdog's monitor and inherits the same guarantee.
// It adds no environment variable (CLAUDE.md's standing rule) and no
// configuration: the interval is a constant, and setting
// `CHICKADEE_WORKERTESTS_STALL_SECONDS=0` to disable the watchdog's abort
// deliberately does NOT disable this — recording evidence is safe even where
// aborting is not.

import Foundation
import Synchronization

public enum StarvationRecorder {
    /// Every line carries this prefix so a whole run's telemetry is one
    /// `grep` away in a 13,000-line CI log.
    public static let linePrefix = "[ci-pressure]"

    /// Seconds between samples. A constant rather than a knob: the value only
    /// has to be short enough to catch the shape of a 25-minute job and long
    /// enough to stay out of the way of a 5-minute one.
    public static let sampleIntervalSeconds: TimeInterval = 30

    private struct State {
        var started = false
        var armedAt: HostCounters?
        var previous: HostCounters?
    }

    private static let state = Mutex(State())

    /// True once the sampling thread is running. Read by the arming guard.
    public static var isRunning: Bool {
        state.withLock { $0.started }
    }

    /// Starts the sampling thread, once per process.
    ///
    /// Runs on a dedicated OS thread for the same reason the wedge watchdog
    /// does: the cooperative pool is the thing under suspicion, and an
    /// observer scheduled on it reports nothing precisely when it matters.
    public static func start() {
        let shouldStart = state.withLock { current -> Bool in
            guard !current.started else { return false }
            current.started = true
            return true
        }
        guard shouldStart else { return }
        // Everything expensive happens on the new thread. The one caller is
        // `WedgeWatchdog.startMonitorIfNeeded`, which runs inside the
        // watchdog's own state lock on the hot `track` path, and the arming
        // sample walks `/proc` — doing that under a lock every test body
        // contends for would be a self-inflicted version of the problem this
        // file exists to measure.
        Thread.detachNewThread {
            let armed = HostCounters.capture(monotonicSeconds: monotonicSeconds())
            state.withLock {
                $0.armedAt = armed
                $0.previous = armed
            }
            RawStandardError.write(armingLine(armed))
            sampleLoop()
        }
    }

    /// Takes one sample and emits it. Exposed so a test can drive the
    /// recorder without waiting 30 seconds for the thread.
    @discardableResult
    public static func sampleAndEmit() -> String {
        let current = HostCounters.capture(monotonicSeconds: monotonicSeconds())
        let (previous, armed) = state.withLock { existing -> (HostCounters?, HostCounters?) in
            let previous = existing.previous
            existing.previous = current
            if existing.armedAt == nil { existing.armedAt = current }
            return (previous, existing.armedAt)
        }
        let line = render(previous: previous, armed: armed, current: current)
        RawStandardError.write(line)
        return line
    }

    private static func sampleLoop() {
        while true {
            Thread.sleep(forTimeInterval: sampleIntervalSeconds)
            sampleAndEmit()
        }
    }

    /// A monotonic clock, so a sample window is never distorted by NTP
    /// stepping the wall clock — which a freshly booted hosted runner does.
    public static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Rendering

    /// The first line: the static facts a reader needs before any rate means
    /// anything, plus which counters this kernel actually offers.
    public static func armingLine(_ counters: HostCounters) -> String {
        var fields = ["\(linePrefix) armed", "cpus=\(counters.onlineCPUs)"]
        fields.append("quota=" + (counters.cgroupCPU?.quotaCores.map { "\(fmt($0))cores" } ?? "none"))
        fields.append("mem_avail=" + (counters.availableMemoryBytes.map(binaryBytes) ?? "-"))
        fields.append("host_psi=" + (counters.hostCPUPressure == nil ? "no" : "yes"))
        fields.append("cgroup_psi=" + (counters.cgroupCPUPressure == nil ? "no" : "yes"))
        fields.append("interval=\(Int(sampleIntervalSeconds))s")
        return fields.joined(separator: " ") + "\n"
    }

    /// One sample line, plus a hint line when a rule below fires.
    ///
    /// Percentages are of WALL TIME in the window, not of CPU capacity, except
    /// `self cpu` and `busy`, which are of total CPU capacity (so 100% means
    /// every core, all window). PSI totals are wall-clock stall microseconds,
    /// so dividing by the window is exact for exactly that window — which is
    /// why the recorder keeps raw totals and never reads the kernel's decayed
    /// `avg10`/`avg60` columns.
    public static func render(previous: HostCounters?, armed: HostCounters?, current: HostCounters) -> String {
        let window = PressureWindow(from: previous, to: current)
        let sinceArm = PressureWindow(from: armed, to: current)
        var line =
            "\(linePrefix) t=\(Int(current.monotonicSeconds - (armed?.monotonicSeconds ?? current.monotonicSeconds)))s"
        line += " | win=\(fmt(window.seconds))s " + window.hostFields()
        line += " | self " + window.selfFields(current: current)
        line += " | load=" + (current.loadAverage1.map(fmt) ?? "-")
        line += " runq=" + runQueue(current)
        line += " | run(\(fmt(sinceArm.seconds))s) " + sinceArm.cumulativeFields()
        line += "\n"
        if let hint = window.hint() {
            line += "\(linePrefix) HINT \(hint)\n"
        }
        return line
    }

    private static func runQueue(_ counters: HostCounters) -> String {
        guard let runnable = counters.runnableEntities, let total = counters.totalEntities else { return "-" }
        return "\(runnable)/\(total)"
    }

    static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "-"
    }

    static func binaryBytes(_ bytes: Int) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1_024, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        return String(format: "%.1f%@", value, units[unit])
    }
}
