// Tests/TestSupport/HostCounters.swift
//
// One point-in-time read of every kernel counter `StarvationRecorder` needs,
// plus the parsers for the `/proc` and cgroup text formats it reads.
//
// Split from the recorder so the parsing is testable without a thread, a
// clock, or a starved machine: every function here is pure, takes the file
// contents as a string, and returns `nil` rather than guessing when the
// format is not what it expects. `StarvationRecorderTests` feeds them
// captured fixtures, so a kernel that renames a field fails a named test
// instead of silently reporting zeros for the rest of the project's life.
//
// Everything is optional by design. These paths are Linux-only, several are
// kernel-config-dependent (PSI needs CONFIG_PSI), and the cgroup layout
// differs between v1 and v2 — a recorder that traps on a missing file would
// take out every test run on a developer's Mac.

import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// A pressure-stall-information reading: microseconds of stall accumulated
/// since boot, for the two PSI classes.
///
/// `some` counts time in which at least one task was stalled on the resource;
/// `full` counts time in which EVERY task was. `full` is the one that means
/// the machine got no useful work done, which is why the recorder reports
/// both and reads them differently.
public struct PressureTotals: Sendable, Equatable {
    public var someMicroseconds: Int
    public var fullMicroseconds: Int

    public init(someMicroseconds: Int, fullMicroseconds: Int) {
        self.someMicroseconds = someMicroseconds
        self.fullMicroseconds = fullMicroseconds
    }
}

/// The aggregate `cpu` line of `/proc/stat`, in USER_HZ ticks.
///
/// `steal` is the field that matters most here: on a virtual machine it is
/// time the hypervisor gave to somebody else's VM. It is the only direct,
/// first-party measurement of a noisy neighbour on the physical host — PSI and
/// load average cannot see outside this VM at all.
public struct CPUTicks: Sendable, Equatable {
    public var user: Int
    public var nice: Int
    public var system: Int
    public var idle: Int
    public var iowait: Int
    public var irq: Int
    public var softirq: Int
    public var steal: Int

    public var total: Int { user + nice + system + idle + iowait + irq + softirq + steal }
    public var busy: Int { total - idle - iowait }

    public init(
        user: Int, nice: Int, system: Int, idle: Int,
        iowait: Int, irq: Int, softirq: Int, steal: Int
    ) {
        self.user = user
        self.nice = nice
        self.system = system
        self.idle = idle
        self.iowait = iowait
        self.irq = irq
        self.softirq = softirq
        self.steal = steal
    }
}

/// The container's own CPU accounting and throttling counters.
///
/// `throttledMicroseconds` rising is the unambiguous signature of hitting a
/// cgroup CPU quota: the kernel stopped us on purpose. A job that is slow with
/// this flat was not slowed by its own quota, whatever else was going on.
public struct CGroupCPU: Sendable, Equatable {
    public var usageMicroseconds: Int?
    public var throttledPeriods: Int?
    public var throttledMicroseconds: Int?
    /// Cores of quota, or nil for "no quota" — `cpu.max` reading `max`.
    public var quotaCores: Double?

    public init(
        usageMicroseconds: Int?, throttledPeriods: Int?,
        throttledMicroseconds: Int?, quotaCores: Double?
    ) {
        self.usageMicroseconds = usageMicroseconds
        self.throttledPeriods = throttledPeriods
        self.throttledMicroseconds = throttledMicroseconds
        self.quotaCores = quotaCores
    }
}

/// `/proc/self/stat` for the test process itself.
public struct ProcessTicks: Sendable, Equatable {
    public var userTicks: Int
    public var systemTicks: Int
    public var reapedChildTicks: Int
    public var threadCount: Int
    public var residentPages: Int

    public var totalTicks: Int { userTicks + systemTicks + reapedChildTicks }

    public init(
        userTicks: Int, systemTicks: Int, reapedChildTicks: Int,
        threadCount: Int, residentPages: Int
    ) {
        self.userTicks = userTicks
        self.systemTicks = systemTicks
        self.reapedChildTicks = reapedChildTicks
        self.threadCount = threadCount
        self.residentPages = residentPages
    }
}

/// Everything read in one sample. Fields are independently optional so a
/// kernel missing one counter still reports the rest.
public struct HostCounters: Sendable {
    public var monotonicSeconds: Double
    public var onlineCPUs: Int
    public var cpuTicks: CPUTicks?
    public var hostCPUPressure: PressureTotals?
    public var hostIOPressure: PressureTotals?
    public var hostMemoryPressure: PressureTotals?
    public var cgroupCPUPressure: PressureTotals?
    public var cgroupCPU: CGroupCPU?
    public var process: ProcessTicks?
    public var loadAverage1: Double?
    public var runnableEntities: Int?
    public var totalEntities: Int?
    public var processCount: Int?
    public var childCount: Int?
    public var availableMemoryBytes: Int?
    /// Not a kernel counter: `WedgeWatchdog.completedTrackedScopes` at the
    /// moment of the sample. It rides along here because a pressure reading
    /// without a throughput reading beside it cannot answer any question worth
    /// asking.
    public var completedScopes: Int?

    public init(monotonicSeconds: Double, onlineCPUs: Int) {
        self.monotonicSeconds = monotonicSeconds
        self.onlineCPUs = onlineCPUs
    }
}

// MARK: - Parsers

public enum HostCounterParsing {
    /// Parses `/proc/pressure/<resource>` (and the identically-formatted
    /// cgroup `*.pressure` files).
    ///
    ///     some avg10=0.00 avg60=0.00 avg300=0.00 total=1805978
    ///     full avg10=0.00 avg60=0.00 avg300=0.00 total=0
    ///
    /// Only `total` is kept. The `avg*` columns are decayed averages over
    /// windows the recorder does not control; a delta of `total` across two
    /// samples is an exact stall time for exactly the interval between them.
    public static func pressureTotals(_ text: String) -> PressureTotals? {
        var some: Int?
        var full: Int?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let kind = fields.first else { continue }
            let total = fields.compactMap { field -> Int? in
                guard field.hasPrefix("total=") else { return nil }
                return Int(field.dropFirst("total=".count))
            }.first
            guard let total else { continue }
            if kind == "some" { some = total }
            if kind == "full" { full = total }
        }
        guard let some else { return nil }
        // `/proc/pressure/cpu` has no `full` line on some kernels — that is a
        // documented absence (CPU pressure is meaningless when every task is
        // stalled), not a parse failure.
        return PressureTotals(someMicroseconds: some, fullMicroseconds: full ?? 0)
    }

    /// Parses the aggregate `cpu` line of `/proc/stat`.
    public static func cpuTicks(_ text: String) -> CPUTicks? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        let values = line.split(separator: " ").dropFirst().compactMap { Int($0) }
        guard values.count >= 8 else { return nil }
        return CPUTicks(
            user: values[0], nice: values[1], system: values[2], idle: values[3],
            iowait: values[4], irq: values[5], softirq: values[6], steal: values[7])
    }

    /// Parses cgroup v2 `cpu.stat`, or cgroup v1's differently-named subset.
    ///
    /// v1 spells the throttle counter `throttled_time` and reports it in
    /// NANOseconds; v2 spells it `throttled_usec`. Reading only the v2 name
    /// would report "never throttled" forever on a v1 host, which is the
    /// failure mode this whole file is written to avoid.
    public static func cgroupCPUStat(_ text: String) -> CGroupCPU {
        var fields: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let value = Int(parts[1]) else { continue }
            fields[String(parts[0])] = value
        }
        let throttledMicroseconds =
            fields["throttled_usec"] ?? fields["throttled_time"].map { $0 / 1_000 }
        return CGroupCPU(
            usageMicroseconds: fields["usage_usec"],
            throttledPeriods: fields["nr_throttled"],
            throttledMicroseconds: throttledMicroseconds,
            quotaCores: nil)
    }

    /// Parses cgroup v2 `cpu.max` — `"max 100000"` (no quota) or
    /// `"200000 100000"` (two cores' worth).
    public static func cgroupQuotaCores(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let period = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
            period > 0
        else { return nil }
        guard let quota = Double(parts[0]) else { return nil }
        return quota / period
    }

    /// Parses cgroup v1's quota pair (`cpu.cfs_quota_us` / `cpu.cfs_period_us`).
    /// A quota of -1 means unlimited.
    public static func cgroupV1QuotaCores(quota: String, period: String) -> Double? {
        guard let quota = Double(quota.trimmingCharacters(in: .whitespacesAndNewlines)),
            let period = Double(period.trimmingCharacters(in: .whitespacesAndNewlines)),
            quota > 0, period > 0
        else { return nil }
        return quota / period
    }

    /// Parses `/proc/loadavg`: `0.31 0.42 0.38 9/186 12345`.
    public static func loadAverage(_ text: String) -> (load1: Double, runnable: Int, total: Int)? {
        let fields = text.split(separator: " ")
        guard fields.count >= 4, let load1 = Double(fields[0]) else { return nil }
        let entities = fields[3].split(separator: "/")
        guard entities.count == 2, let runnable = Int(entities[0]), let total = Int(entities[1]) else { return nil }
        return (load1, runnable, total)
    }

    /// Parses `/proc/<pid>/stat`.
    ///
    /// The `comm` field is the process name in parentheses and may itself
    /// contain spaces and parentheses, so every numeric field is located
    /// relative to the LAST `)` rather than by splitting the whole line. Field
    /// 3 (state) is the first field after it, so field N is at offset N - 3.
    public static func processTicks(_ text: String) -> ProcessTicks? {
        guard let closingParen = text.lastIndex(of: ")") else { return nil }
        let tail = text[text.index(after: closingParen)...].split(separator: " ")
        func field(_ number: Int) -> Int? {
            let index = number - 3
            guard index >= 0, index < tail.count else { return nil }
            return Int(tail[index])
        }
        guard let userTicks = field(14), let systemTicks = field(15),
            let childUser = field(16), let childSystem = field(17),
            let threadCount = field(20), let residentPages = field(24)
        else { return nil }
        return ProcessTicks(
            userTicks: userTicks, systemTicks: systemTicks,
            reapedChildTicks: childUser + childSystem,
            threadCount: threadCount, residentPages: residentPages)
    }

    /// Parses the parent PID (field 4) out of `/proc/<pid>/stat`.
    public static func parentPID(_ text: String) -> Int? {
        guard let closingParen = text.lastIndex(of: ")") else { return nil }
        let tail = text[text.index(after: closingParen)...].split(separator: " ")
        guard tail.count > 1 else { return nil }
        return Int(tail[1])
    }

    /// Parses `MemAvailable` out of `/proc/meminfo`, in bytes.
    public static func availableMemoryBytes(_ text: String) -> Int? {
        for line in text.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let kibibytes = Int(fields[1]) else { return nil }
            return kibibytes * 1_024
        }
        return nil
    }
}
