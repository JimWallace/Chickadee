// Tests/WorkerTests/JobMemoryBudgetTests.swift
//
// #2252: a job's memory limit protects the jobs beside it only when the
// container can hold every job at that limit. These tests prove that the
// runner warns, with values that fit, when the container's memory limit is
// too small; and that a job the kernel stopped because the container ran out
// is not told that it went over its own limit.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct JobMemoryBudgetTests {

    private let megabyte = 1024 * 1024

    @Test func theRequiredLimitCoversEveryJobAndTheRunner() {
        let budget = JobMemoryBudget(containerLimitBytes: 4608 * megabyte, maxJobs: 4, memoryLimitMegabytes: 1024)
        #expect(budget.requiredMegabytes == 4 * 1024 + JobMemoryBudget.runnerReserveMegabytes)
        #expect(budget.warning == nil)
    }

    @Test func aContainerLimitBelowTheRequiredOneWarnsWithTheValuesToSet() throws {
        let budget = JobMemoryBudget(containerLimitBytes: 2048 * megabyte, maxJobs: 4, memoryLimitMegabytes: 1024)
        let warning = try #require(budget.warning)
        #expect(warning.contains("at least 4608 MB"))
        #expect(warning.contains("--max-jobs"))
        #expect(warning.contains("--job-memory-limit 384 fits"))
    }

    @Test func noJobLimitIsSuggestedWhenNoneFits() throws {
        let budget = JobMemoryBudget(containerLimitBytes: 256 * megabyte, maxJobs: 4, memoryLimitMegabytes: 1024)
        #expect(budget.fittingJobLimitMegabytes == nil)
        let warning = try #require(budget.warning)
        #expect(!warning.contains("fits"))
    }

    @Test func theContainerLimitIsReadFromTheFirstReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing").path
        let limited = directory.appendingPathComponent("limited").path
        let unlimited = directory.appendingPathComponent("unlimited").path
        try "2147483648\n".write(toFile: limited, atomically: true, encoding: .utf8)
        try "max\n".write(toFile: unlimited, atomically: true, encoding: .utf8)

        #expect(JobMemoryBudget.readContainerLimit(paths: [missing, limited]) == 2_147_483_648)
        #expect(JobMemoryBudget.readContainerLimit(paths: [unlimited, limited]) == nil)
        #expect(JobMemoryBudget.readContainerLimit(paths: [missing]) == nil)
    }
}

@Suite struct JobMemoryStopMessageTests {

    @Test func aJobThatReachedItsOwnLimitIsToldSo() throws {
        let events = "low 0\nhigh 0\nmax 40\noom 1\noom_kill 1\noom_group_kill 0\n"
        let message = try #require(SandboxedScriptRunner.memoryStopMessage(memoryEvents: events, megabytes: 1024))
        #expect(message == SandboxedScriptRunner.memoryLimitMessage(megabytes: 1024))
    }

    /// The container reached its limit: the kernel stopped a process in this
    /// job, but the job's own `oom` count did not move.
    @Test func aJobStoppedBecauseTheContainerRanOutIsNotBlamed() throws {
        let events = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 1\noom_group_kill 0\n"
        let message = try #require(SandboxedScriptRunner.memoryStopMessage(memoryEvents: events, megabytes: 1024))
        #expect(message.contains("the runner ran out of memory"))
        #expect(!message.contains("used more than"))
    }

    @Test func aJobThatWasNotStoppedGetsNoMessage() {
        #expect(SandboxedScriptRunner.memoryStopMessage(memoryEvents: "oom 0\noom_kill 0\n", megabytes: 1024) == nil)
        #expect(SandboxedScriptRunner.memoryStopMessage(memoryEvents: "", megabytes: 1024) == nil)
    }

    /// `oom` must not match `oom_kill` or `oom_group_kill`.
    @Test func theOwnLimitCountReadsOnlyTheOomLine() {
        #expect(JobCgroup.ownLimitOOMs(inMemoryEvents: "oom_kill 3\noom_group_kill 2\n") == 0)
        #expect(JobCgroup.ownLimitOOMs(inMemoryEvents: "oom 2\noom_kill 3\n") == 2)
    }
}
