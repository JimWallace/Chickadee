// Tests/TestSupport/HostCounters+Capture.swift
//
// The `/proc` and cgroup reads behind one `HostCounters` sample.
//
// Separated from the parsers so the parsers stay pure and testable, and from
// the recorder so the recorder stays about scheduling and rendering. Nothing
// here throws or traps: a path that is absent or unreadable leaves its field
// nil, and the renderer prints a dash for it.

import Foundation

#if canImport(Glibc)
import Glibc
#endif

extension HostCounters {
    /// Reads every counter once. Cheap enough to call from a timer thread:
    /// a handful of small `read(2)`s plus one `/proc` directory scan.
    public static func capture(monotonicSeconds: Double) -> HostCounters {
        var counters = HostCounters(
            monotonicSeconds: monotonicSeconds,
            onlineCPUs: ProcessInfo.processInfo.activeProcessorCount)
        counters.cpuTicks = readFile("/proc/stat").flatMap(HostCounterParsing.cpuTicks)
        counters.hostCPUPressure = readFile("/proc/pressure/cpu").flatMap(HostCounterParsing.pressureTotals)
        counters.hostIOPressure = readFile("/proc/pressure/io").flatMap(HostCounterParsing.pressureTotals)
        counters.hostMemoryPressure = readFile("/proc/pressure/memory").flatMap(HostCounterParsing.pressureTotals)
        counters.cgroupCPUPressure = readFile("/sys/fs/cgroup/cpu.pressure")
            .flatMap(HostCounterParsing.pressureTotals)
        counters.cgroupCPU = captureCGroupCPU()
        counters.process = readFile("/proc/self/stat").flatMap(HostCounterParsing.processTicks)
        if let load = readFile("/proc/loadavg").flatMap(HostCounterParsing.loadAverage) {
            counters.loadAverage1 = load.load1
            counters.runnableEntities = load.runnable
            counters.totalEntities = load.total
        }
        counters.availableMemoryBytes = readFile("/proc/meminfo")
            .flatMap(HostCounterParsing.availableMemoryBytes)
        counters.completedScopes = WedgeWatchdog.completedTrackedScopes
        let census = processCensus()
        counters.processCount = census.total
        counters.childCount = census.children
        return counters
    }

    /// cgroup v2 first, then v1. The two disagree on paths, on file names and
    /// on the throttle counter's unit, so the fallback is a real second
    /// implementation rather than a different prefix.
    private static func captureCGroupCPU() -> CGroupCPU? {
        if let stat = readFile("/sys/fs/cgroup/cpu.stat") {
            var cpu = HostCounterParsing.cgroupCPUStat(stat)
            cpu.quotaCores = readFile("/sys/fs/cgroup/cpu.max").flatMap(HostCounterParsing.cgroupQuotaCores)
            return cpu
        }
        guard let stat = readFile("/sys/fs/cgroup/cpu/cpu.stat") else { return nil }
        var cpu = HostCounterParsing.cgroupCPUStat(stat)
        if let quota = readFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us"),
            let period = readFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
        {
            cpu.quotaCores = HostCounterParsing.cgroupV1QuotaCores(quota: quota, period: period)
        }
        return cpu
    }

    /// Counts every process visible in this PID namespace, and how many of
    /// them are our direct children.
    ///
    /// The total is the one that answers "did we spawn a subprocess storm":
    /// inside a CI container this process tree IS the container, so a total
    /// well above the handful of interpreters a test should have running is
    /// self-inflicted load, whatever the host is doing.
    private static func processCensus() -> (total: Int, children: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return (0, 0)
        }
        let selfPID = Int(getpid())
        var total = 0
        var children = 0
        for entry in entries {
            guard let pid = Int(entry) else { continue }
            total += 1
            guard pid != selfPID,
                let stat = readFile("/proc/\(pid)/stat"),
                HostCounterParsing.parentPID(stat) == selfPID
            else { continue }
            children += 1
        }
        return (total, children)
    }

    /// `read(2)` through `FileManager` rather than `String(contentsOfFile:)`:
    /// several `/proc` files report a size of zero, which makes the
    /// length-driven readers return empty.
    public static func readFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
