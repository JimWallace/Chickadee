// Tests/APITests/StarvationRecorderTests.swift
//
// Proof that the Family 5 instrument works, and drift guards for the two ways
// it could silently stop working.
//
// The house rule is that a check never seen to fail is not a check
// (scripts/check-guards.sh). An instrument is the same shape of claim: a
// recorder that has never produced its own artifact is not evidence that it
// will produce one during the incident it was written for — and the incident
// it was written for ENDS IN A KILL, so there is no second chance to notice
// that a field was always a dash.
//
// So these tests cover three layers:
//
//   1. The parsers, against captured `/proc` and cgroup text, including the
//      formats that differ between cgroup v1 and v2 and the `comm`-with-parens
//      case that breaks naive field splitting.
//   2. The verdict rules, against synthesised counters — each of the four
//      causes Family 5 has to separate is driven to its own hint, so the
//      sentence a future postmortem will read has been read once already.
//   3. The live path on this machine: real counters, a real emitted line, and
//      the arming seam that has to keep holding.

import ChickadeeTestSupport
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct StarvationRecorderTests {

    // MARK: - Parsers

    @Test func pressureTotalsReadsBothClasses() throws {
        let text = """
            some avg10=0.00 avg60=0.64 avg300=0.35 total=1805978
            full avg10=0.00 avg60=0.10 avg300=0.05 total=421337
            """
        let totals = try #require(HostCounterParsing.pressureTotals(text))
        #expect(totals.someMicroseconds == 1_805_978)
        #expect(totals.fullMicroseconds == 421_337)
    }

    /// `/proc/pressure/cpu` carries no `full` line on several kernels. That is
    /// a documented absence, not a malformed file, and reading it as a parse
    /// failure would blank every CPU pressure field on those hosts.
    @Test func pressureTotalsToleratesAMissingFullLine() throws {
        let totals = try #require(
            HostCounterParsing.pressureTotals("some avg10=0.03 avg60=0.64 avg300=0.35 total=1805978"))
        #expect(totals.someMicroseconds == 1_805_978)
        #expect(totals.fullMicroseconds == 0)
    }

    @Test func pressureTotalsRejectsTextWithNoTotals() {
        #expect(HostCounterParsing.pressureTotals("some avg10=0.03") == nil)
    }

    /// `steal` is the eighth field and the whole reason this line is read.
    @Test func cpuTicksReadsStealFromTheAggregateLine() throws {
        let text = """
            cpu  1000 20 300 50000 900 10 5 777 0 0
            cpu0 500 10 150 25000 450 5 2 388 0 0
            """
        let ticks = try #require(HostCounterParsing.cpuTicks(text))
        #expect(ticks.steal == 777)
        #expect(ticks.iowait == 900)
        #expect(ticks.total == 1_000 + 20 + 300 + 50_000 + 900 + 10 + 5 + 777)
        #expect(ticks.busy == ticks.total - 50_000 - 900)
    }

    /// cgroup v2 spells the throttle counter `throttled_usec`; v1 spells it
    /// `throttled_time` and reports NANOseconds. Reading only the v2 name
    /// reports "never throttled" forever on a v1 host.
    @Test func cgroupCPUStatReadsBothSpellingsOfTheThrottleCounter() {
        let v2 = HostCounterParsing.cgroupCPUStat(
            """
            usage_usec 123456
            user_usec 90000
            system_usec 33456
            nr_periods 40
            nr_throttled 7
            throttled_usec 8500
            """)
        #expect(v2.usageMicroseconds == 123_456)
        #expect(v2.throttledPeriods == 7)
        #expect(v2.throttledMicroseconds == 8_500)

        let v1 = HostCounterParsing.cgroupCPUStat(
            """
            nr_periods 40
            nr_throttled 7
            throttled_time 8500000
            """)
        #expect(v1.usageMicroseconds == nil)
        #expect(v1.throttledPeriods == 7)
        #expect(v1.throttledMicroseconds == 8_500)
    }

    @Test func quotaIsReadFromBothCGroupLayoutsAndAbsentWhenUnlimited() {
        #expect(HostCounterParsing.cgroupQuotaCores("200000 100000") == 2)
        #expect(HostCounterParsing.cgroupQuotaCores("max 100000") == nil)
        #expect(HostCounterParsing.cgroupV1QuotaCores(quota: "150000", period: "100000") == 1.5)
        #expect(HostCounterParsing.cgroupV1QuotaCores(quota: "-1", period: "100000") == nil)
    }

    /// The `comm` field is the process name in parentheses and may contain
    /// spaces and parentheses of its own, so every numeric field is located
    /// from the LAST `)`. A test binary is routinely named something like
    /// `(xctest (swift))`.
    @Test func processTicksLocatesFieldsAfterAwkwardCommNames() throws {
        // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt
        // majflt cmajflt utime stime cutime cstime priority nice num_threads ...
        let tail = "S 1 1 1 0 -1 4194304 100 0 0 0 4000 500 120 34 20 0 41 0 900 123456789 2048"
        let stat = try #require(HostCounterParsing.processTicks("4242 (xctest (swift)) \(tail)"))
        #expect(stat.userTicks == 4_000)
        #expect(stat.systemTicks == 500)
        #expect(stat.reapedChildTicks == 120 + 34)
        #expect(stat.threadCount == 41)
        #expect(stat.residentPages == 2_048)
        #expect(HostCounterParsing.parentPID("4242 (xctest (swift)) \(tail)") == 1)
    }

    @Test func loadAverageReadsTheRunQueue() throws {
        let load = try #require(HostCounterParsing.loadAverage("6.29 5.11 3.40 9/186 45321"))
        #expect(load.load1 == 6.29)
        #expect(load.runnable == 9)
        #expect(load.total == 186)
    }

    @Test func availableMemoryIsReadInBytes() {
        let text = """
            MemTotal:       16116504 kB
            MemFree:         1204480 kB
            MemAvailable:   12980224 kB
            """
        #expect(HostCounterParsing.availableMemoryBytes(text) == 12_980_224 * 1_024)
    }

    // MARK: - Arithmetic and verdicts

    /// Every cause Family 5 has to separate, driven to its own sentence.
    ///
    /// The ordering matters as much as the thresholds: steal and quota
    /// throttling name a cause outright, so they are reported ahead of the
    /// CPU-share split, which is a judgement. The throttling case below is
    /// deliberately built on a box that is also busy and mostly ours — if the
    /// rules were reordered, it would report the weaker sentence and this test
    /// would say so.
    @Test func eachCauseGetsItsOwnVerdict() {
        let stolen = window(stealTicks: 3_000, busyTicks: 2_000, idleTicks: 5_000)
        #expect(stolen.hint()?.contains("another tenant on the physical host") == true)

        let throttled = window(busyTicks: 9_000, idleTicks: 1_000, selfMicroseconds: 18_000_000, throttledPeriods: 4)
        #expect(throttled.hint()?.contains("CPU-quota throttled in 4 period(s)") == true)

        let blockedOnDisk = window(busyTicks: 1_000, idleTicks: 9_000, ioFullMicroseconds: 12_000_000)
        #expect(blockedOnDisk.hint()?.contains("fully stalled on disk") == true)

        let reclaiming = window(busyTicks: 1_000, idleTicks: 9_000, memoryFullMicroseconds: 3_000_000)
        #expect(reclaiming.hint()?.contains("reclaiming memory") == true)

        let storm = window(busyTicks: 9_000, idleTicks: 1_000, selfMicroseconds: 50_000_000, childCount: 8)
        #expect(storm.hint()?.contains("subprocess") == true)

        let somebodyElseInTheVM = window(busyTicks: 9_000, idleTicks: 1_000, selfMicroseconds: 2_000_000)
        #expect(somebodyElseInTheVM.hint()?.contains("something else in this VM") == true)

        let healthy = window(busyTicks: 2_000, idleTicks: 8_000, selfMicroseconds: 4_000_000)
        #expect(healthy.hint() == nil)
    }

    /// A busy box doing our own work gets NO hint. Every healthy `api-tests`
    /// run looks like this — 70-90 % busy, nearly all of it ours — and a hint
    /// printed on every line of a green log is a hint nobody reads on the one
    /// line that mattered. Measured on a full local run at CI's
    /// parallelization width: busy 69.8-90.9 %, self 68.9-92.2 %.
    @Test func aBusyBoxDoingOurOwnWorkIsNotAFault() {
        let healthyButBusy = window(busyTicks: 9_100, idleTicks: 900, selfMicroseconds: 55_000_000)
        #expect(healthyButBusy.hint() == nil)
    }

    @Test func throughputIsReportedPerMinute() throws {
        let measured = window(busyTicks: 5_000, idleTicks: 5_000, completedScopes: 300)
        let rate = try #require(measured.scopesPerMinute)
        #expect(rate.rounded() == 600)
    }

    @Test func ratesAreExactSharesOfTheWindow() throws {
        // 30 s window, 2 cores: 30 s of CPU used out of 60 s of capacity = 50 %.
        let measured = window(busyTicks: 5_000, idleTicks: 5_000, selfMicroseconds: 30_000_000)
        let ourShare = try #require(measured.selfCPUPercent)
        #expect(ourShare.rounded() == 50)
        // 6 s of the 30 s window fully stalled on I/O = 20 %.
        let stalled = window(busyTicks: 1_000, idleTicks: 9_000, ioFullMicroseconds: 6_000_000)
        let ioStall = try #require(stalled.stallFull(\.hostIOPressure))
        let busy = try #require(stalled.busyPercent)
        #expect(ioStall.rounded() == 20)
        #expect(busy.rounded() == 10)
    }

    /// The line is the artifact. If a field is renamed or dropped, the next
    /// postmortem greps for something that is not there.
    @Test func theEmittedLineCarriesEveryFieldAPostmortemNeeds() {
        let samples = counters(stealTicks: 100, busyTicks: 6_000, idleTicks: 3_900, selfMicroseconds: 40_000_000)
        let rendered = StarvationRecorder.render(
            previous: samples.start, armed: samples.start, current: samples.end)
        for field in [
            "[ci-pressure]", "win=", "cpu_some=", "cpu_full=", "io_some=", "io_full=", "mem_full=",
            "steal=", "iowait=", "busy=", "self cpu=", "thr=", "procs=", "kids=", "rss=",
            "throttled=", "scopes=", "load=", "runq=", "run(",
        ] {
            #expect(rendered.contains(field), "rendered line is missing \(field): \(rendered)")
        }
    }

    // MARK: - The live path

    /// The counters this machine actually offers. A kernel without PSI is a
    /// legitimate outcome (the recorder prints dashes and says `host_psi=no`
    /// in its arming line), so only the universally-available fields are
    /// asserted — but they are asserted against a real read, not a fixture.
    @Test func captureReadsRealCountersOnThisMachine() throws {
        let counters = HostCounters.capture(monotonicSeconds: StarvationRecorder.monotonicSeconds())
        #expect(counters.onlineCPUs >= 1)
        #if os(Linux)
        let process = try #require(counters.process, "/proc/self/stat should be readable on Linux")
        #expect(process.threadCount >= 1)
        #expect(try #require(counters.cpuTicks).total > 0)
        #expect(try #require(counters.processCount) >= 1)
        #endif
    }

    /// Seen to fire: two real samples around a real CPU burn, and the recorder
    /// reports CPU it can only have measured.
    @Test func aRealWindowMeasuresRealCPU() throws {
        #if os(Linux)
        let before = HostCounters.capture(monotonicSeconds: StarvationRecorder.monotonicSeconds())
        var sink: UInt64 = 0
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            for value in 0..<50_000 { sink = sink &+ UInt64(value) &* 2_654_435_761 }
        }
        #expect(sink != 0)
        let after = HostCounters.capture(monotonicSeconds: StarvationRecorder.monotonicSeconds())
        let measured = PressureWindow(from: before, to: after)
        #expect(measured.seconds > 0)
        let ourShare = try #require(measured.selfCPUPercent, "no CPU accounting available for this process")
        #expect(ourShare > 0, "burned a second of CPU and the recorder measured \(ourShare)%")
        #expect(measured.selfFields(current: after).contains("cpu="))
        #endif
    }

    @Test func sampleAndEmitWritesAPrefixedLine() {
        let line = StarvationRecorder.sampleAndEmit()
        #expect(line.hasPrefix(StarvationRecorder.linePrefix))
        #expect(line.hasSuffix("\n"))
    }

    /// Drift guard for the arming seam.
    ///
    /// The recorder deliberately has no arming call of its own: it starts with
    /// `WedgeWatchdog`'s monitor, which APITests arms at `withApp`. That
    /// borrows the watchdog's guarantee, and this test is what keeps the
    /// borrowing honest — if the recorder is ever unhooked from that seam, a
    /// Family 5 job goes back to leaving no evidence, and every other test
    /// still passes.
    @Test func theWatchdogSeamArmsTheRecorder() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { _ in
            #expect(StarvationRecorder.isRunning)
        }
    }

    // MARK: - Fixture builder

    /// Builds a two-sample window over 30 s on a 2-core box. Only the counters
    /// a case cares about are set; everything else stays zero so a verdict can
    /// never be satisfied by a field the case did not mean to exercise.
    private func window(
        stealTicks: Int = 0,
        busyTicks: Int = 0,
        idleTicks: Int = 0,
        selfMicroseconds: Int = 0,
        ioFullMicroseconds: Int = 0,
        memoryFullMicroseconds: Int = 0,
        throttledPeriods: Int = 0,
        completedScopes: Int = 0,
        childCount: Int = 2
    ) -> PressureWindow {
        let samples = counters(
            stealTicks: stealTicks, busyTicks: busyTicks, idleTicks: idleTicks,
            selfMicroseconds: selfMicroseconds, ioFullMicroseconds: ioFullMicroseconds,
            memoryFullMicroseconds: memoryFullMicroseconds, throttledPeriods: throttledPeriods,
            completedScopes: completedScopes, childCount: childCount)
        return PressureWindow(from: samples.start, to: samples.end)
    }

    private func counters(
        stealTicks: Int = 0,
        busyTicks: Int = 0,
        idleTicks: Int = 0,
        selfMicroseconds: Int = 0,
        ioFullMicroseconds: Int = 0,
        memoryFullMicroseconds: Int = 0,
        throttledPeriods: Int = 0,
        completedScopes: Int = 0,
        childCount: Int = 2
    ) -> (start: HostCounters, end: HostCounters) {
        var start = HostCounters(monotonicSeconds: 100, onlineCPUs: 2)
        start.cpuTicks = CPUTicks(user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0)
        start.hostIOPressure = PressureTotals(someMicroseconds: 0, fullMicroseconds: 0)
        start.hostMemoryPressure = PressureTotals(someMicroseconds: 0, fullMicroseconds: 0)
        start.hostCPUPressure = PressureTotals(someMicroseconds: 0, fullMicroseconds: 0)
        start.cgroupCPU = CGroupCPU(
            usageMicroseconds: 0, throttledPeriods: 0, throttledMicroseconds: 0, quotaCores: nil)
        start.completedScopes = 0

        var end = HostCounters(monotonicSeconds: 130, onlineCPUs: 2)
        end.cpuTicks = CPUTicks(
            user: busyTicks, nice: 0, system: 0, idle: idleTicks,
            iowait: 0, irq: 0, softirq: 0, steal: stealTicks)
        end.hostIOPressure = PressureTotals(someMicroseconds: ioFullMicroseconds, fullMicroseconds: ioFullMicroseconds)
        end.hostMemoryPressure = PressureTotals(
            someMicroseconds: memoryFullMicroseconds, fullMicroseconds: memoryFullMicroseconds)
        end.hostCPUPressure = PressureTotals(someMicroseconds: 0, fullMicroseconds: 0)
        end.cgroupCPU = CGroupCPU(
            usageMicroseconds: selfMicroseconds, throttledPeriods: throttledPeriods,
            throttledMicroseconds: 0, quotaCores: nil)
        end.process = ProcessTicks(
            userTicks: 0, systemTicks: 0, reapedChildTicks: 0, threadCount: 12, residentPages: 4_096)
        end.processCount = 9
        end.childCount = childCount
        end.completedScopes = completedScopes
        end.loadAverage1 = 4.5
        end.runnableEntities = 6
        end.totalEntities = 140
        return (start, end)
    }
}
