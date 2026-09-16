// Tests/TestSupport/PressureWindow.swift
//
// The arithmetic between two `HostCounters` samples, and the rules that turn
// it into a one-sentence verdict.
//
// Kept separate from `StarvationRecorder` because this is the part with an
// opinion: the thresholds below are what a future reader will argue with, and
// they should be readable without wading through thread management. Every
// counter the kernel gives us is a monotonic total, so a rate is always a
// difference divided by the window — there is no averaging, smoothing or
// decay anywhere in this file, and the numbers in a line are true of exactly
// the interval that line names.

import Foundation

#if canImport(Glibc)
import Glibc
#endif

public struct PressureWindow: Sendable {
    public let seconds: Double
    private let start: HostCounters?
    private let end: HostCounters

    public init(from start: HostCounters?, to end: HostCounters) {
        self.start = start
        self.end = end
        self.seconds = start.map { end.monotonicSeconds - $0.monotonicSeconds } ?? 0
    }

    // MARK: - Rates

    /// Share of the window during which at least one task was stalled on the
    /// resource. PSI totals are wall-clock microseconds, so this is a true
    /// percentage of elapsed time.
    public func stallSome(_ keyPath: KeyPath<HostCounters, PressureTotals?>) -> Double? {
        rate(delta(keyPath, \.someMicroseconds))
    }

    /// Share of the window during which EVERY task was stalled — the machine
    /// did no useful work at all. This is the damaging one.
    public func stallFull(_ keyPath: KeyPath<HostCounters, PressureTotals?>) -> Double? {
        rate(delta(keyPath, \.fullMicroseconds))
    }

    /// Share of total CPU capacity the hypervisor gave to another virtual
    /// machine. Nothing in this repository can lower this number.
    public var stealPercent: Double? { cpuShare(\.steal) }

    /// Share of total CPU capacity that was doing work for anybody in this VM.
    public var busyPercent: Double? { cpuShare(\.busy) }

    /// Share of total CPU capacity spent waiting on disk.
    public var ioWaitPercent: Double? { cpuShare(\.iowait) }

    /// Share of total CPU capacity consumed by this test process and the
    /// children it has reaped.
    ///
    /// Prefers the cgroup's own `usage_usec`, which counts every process in
    /// the container whether or not we have waited for it; `/proc/self/stat`
    /// only gains a child's time at reap, so a storm of still-running
    /// interpreters would be invisible there.
    public var selfCPUPercent: Double? {
        guard seconds > 0, end.onlineCPUs > 0 else { return nil }
        let capacity = seconds * Double(end.onlineCPUs)
        if let usage = delta(\.cgroupCPU?.usageMicroseconds) {
            return (Double(usage) / 1_000_000) / capacity * 100
        }
        guard let ticks = delta(\.process?.totalTicks) else { return nil }
        return (Double(ticks) / clockTicksPerSecond) / capacity * 100
    }

    /// Periods in which the kernel stopped the container for exceeding its
    /// CPU quota. Any non-zero value is a direct answer to "were we throttled".
    public var throttledPeriods: Int? { delta(\.cgroupCPU?.throttledPeriods) }

    /// Tracked scopes — in APITests, test bodies — that finished per minute.
    /// This is the "is it actually slow" half of every line.
    public var scopesPerMinute: Double? {
        guard let finished = delta(\.completedScopes), seconds > 0 else { return nil }
        return Double(finished) / seconds * 60
    }

    // MARK: - Rendering

    public func hostFields() -> String {
        let fields = [
            "cpu_some=" + StarvationRecorder.percent(stallSome(\.hostCPUPressure)),
            "cpu_full=" + StarvationRecorder.percent(stallFull(\.hostCPUPressure)),
            "io_some=" + StarvationRecorder.percent(stallSome(\.hostIOPressure)),
            "io_full=" + StarvationRecorder.percent(stallFull(\.hostIOPressure)),
            "mem_full=" + StarvationRecorder.percent(stallFull(\.hostMemoryPressure)),
            "steal=" + StarvationRecorder.percent(stealPercent),
            "iowait=" + StarvationRecorder.percent(ioWaitPercent),
            "busy=" + StarvationRecorder.percent(busyPercent),
        ]
        return fields.joined(separator: " ")
    }

    public func selfFields(current: HostCounters) -> String {
        var fields = ["cpu=" + StarvationRecorder.percent(selfCPUPercent)]
        fields.append("scopes=" + (scopesPerMinute.map { "\(StarvationRecorder.fmt($0))/min" } ?? "-"))
        fields.append("thr=" + (current.process.map { "\($0.threadCount)" } ?? "-"))
        fields.append("procs=" + (current.processCount.map { "\($0)" } ?? "-"))
        fields.append("kids=" + (current.childCount.map { "\($0)" } ?? "-"))
        fields.append(
            "rss=" + (current.process.map { StarvationRecorder.binaryBytes($0.residentPages * pageSize) } ?? "-"))
        fields.append("throttled=" + (throttledPeriods.map { "+\($0)" } ?? "-"))
        // Our container's OWN CPU pressure, next to the host's. The two differ
        // by exactly what everything else on the box is doing, so a host
        // `cpu_some` far above this one is another tenant and a host figure
        // that tracks it is us. Absent (`-`) on cgroup v1, where the kernel
        // does not export per-cgroup PSI at all.
        fields.append("cg_cpu_some=" + StarvationRecorder.percent(stallSome(\.cgroupCPUPressure)))
        return fields.joined(separator: " ")
    }

    public func cumulativeFields() -> String {
        let fields = [
            "cpu_some=" + StarvationRecorder.percent(stallSome(\.hostCPUPressure)),
            "io_full=" + StarvationRecorder.percent(stallFull(\.hostIOPressure)),
            "mem_full=" + StarvationRecorder.percent(stallFull(\.hostMemoryPressure)),
            "steal=" + StarvationRecorder.percent(stealPercent),
            "self_cpu=" + StarvationRecorder.percent(selfCPUPercent),
            "throttled=" + (throttledPeriods.map { "\($0)" } ?? "-"),
            "scopes=" + (scopesPerMinute.map { "\(StarvationRecorder.fmt($0))/min" } ?? "-"),
        ]
        return fields.joined(separator: " ")
    }

    // MARK: - Verdict

    /// The one sentence a future reader of a killed job's log needs.
    ///
    /// Ordered by how decisive the evidence is, not by severity: steal and
    /// quota throttling are unambiguous and name a cause outright, so they
    /// come first; the CPU-share split is a judgement and comes last. Only
    /// the first matching rule is reported — a line carrying six hints is a
    /// line nobody reads.
    ///
    /// On CI the disk rule is expected to stay quiet, because both APITests
    /// lanes now run with `/tmp` on a tmpfs. Running the suite locally on a
    /// real filesystem trips it on nearly every window, and that is correct
    /// rather than noise: it is the finding those lanes were changed for.
    public func hint() -> String? {
        if let steal = stealPercent, steal >= 10 {
            return "\(StarvationRecorder.percent(steal)) of this VM's CPU went to another tenant on the "
                + "physical host (steal). The machine was taken from us — not a Chickadee defect."
        }
        if let throttled = throttledPeriods, throttled > 0 {
            return "the container was CPU-quota throttled in \(throttled) period(s) this window. "
                + "We are over our allowance; this is ours."
        }
        if let ioFull = stallFull(\.hostIOPressure), ioFull >= 20 {
            return "the machine was fully stalled on disk for \(StarvationRecorder.percent(ioFull)) of this "
                + "window. Throughput is bound by I/O latency, not CPU."
        }
        if let memoryFull = stallFull(\.hostMemoryPressure), memoryFull >= 5 {
            return "the machine was fully stalled reclaiming memory for "
                + "\(StarvationRecorder.percent(memoryFull)) of this window."
        }
        if let children = end.childCount, end.onlineCPUs > 0, children >= 4 * end.onlineCPUs {
            return "\(children) live child processes against \(end.onlineCPUs) CPU(s) — a subprocess "
                + "storm, which is self-inflicted. 21 APITests files spawn real interpreters."
        }
        guard let busy = busyPercent, let ours = selfCPUPercent, busy >= 60, ours <= 0.4 * busy else {
            // Deliberately silent for "the box is busy and the work is ours".
            // That is what a test suite is FOR, it is true of every healthy
            // `api-tests` run, and a hint on every line of a green log is a
            // hint nobody reads on the one line that mattered. The `self cpu`
            // field carries the number regardless.
            return nil
        }
        return "the box is \(StarvationRecorder.percent(busy)) busy but only "
            + "\(StarvationRecorder.percent(ours)) is ours — something else in this VM is using it. "
            + "A service container counts: on the api-tests-postgres lane the database is a "
            + "co-tenant and takes about half the machine, which is expected."
    }

    // MARK: - Helpers

    private func rate(_ microseconds: Int?) -> Double? {
        guard let microseconds, seconds > 0 else { return nil }
        return (Double(microseconds) / 1_000_000) / seconds * 100
    }

    private func cpuShare(_ keyPath: KeyPath<CPUTicks, Int>) -> Double? {
        guard let start = start?.cpuTicks, let end = end.cpuTicks else { return nil }
        let total = end.total - start.total
        guard total > 0 else { return nil }
        return Double(end[keyPath: keyPath] - start[keyPath: keyPath]) / Double(total) * 100
    }

    private func delta(
        _ keyPath: KeyPath<HostCounters, PressureTotals?>,
        _ field: KeyPath<PressureTotals, Int>
    ) -> Int? {
        guard let start = start?[keyPath: keyPath], let end = end[keyPath: keyPath] else { return nil }
        return end[keyPath: field] - start[keyPath: field]
    }

    private func delta(_ keyPath: KeyPath<HostCounters, Int?>) -> Int? {
        guard let start = start?[keyPath: keyPath], let end = end[keyPath: keyPath] else { return nil }
        return end - start
    }

    private var clockTicksPerSecond: Double {
        #if canImport(Glibc)
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        return ticks > 0 ? Double(ticks) : 100
        #else
        return 100
        #endif
    }

    private var pageSize: Int {
        #if canImport(Glibc)
        let size = sysconf(Int32(_SC_PAGESIZE))
        return size > 0 ? Int(size) : 4_096
        #else
        return 4_096
        #endif
    }
}
