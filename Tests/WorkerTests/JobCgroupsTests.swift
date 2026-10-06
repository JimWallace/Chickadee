// Tests/WorkerTests/JobCgroupsTests.swift
//
// #2252: each sandboxed command runs in a cgroup of its own, under
// `--job-memory-limit`, inside the subtree that deploy/runner-entrypoint.sh
// delegates. A cgroup needs a host with cgroup v2 and that delegation, which
// only the image build in docker-build.yml has: it starts the runner there and
// requires `job_cgroups: enabled`, which the startup probe below decides.
// These tests cover the decisions around the kernel: finding the subtree,
// reading the probe and `memory.events`, cleaning up a cgroup that could not
// be set up, and the flag reaching the runner.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite final class JobCgroupsDiscoveryTests {

    /// A stand-in for /sys/fs/cgroup.
    private let mountPoint: URL

    init() throws {
        mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cgroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Lays out `<mount>/<parent>/jobs` with the given controllers enabled.
    @discardableResult
    private func makeJobs(under parent: String, controllers: String) throws -> URL {
        let jobs = mountPoint.appendingPathComponent(parent, isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try controllers.write(
            to: jobs.appendingPathComponent("cgroup.subtree_control"), atomically: true, encoding: .utf8)
        return jobs
    }

    @Test func theJobsCgroupBesideTheRunnerIsFound() throws {
        let jobs = try makeJobs(under: "sandbox", controllers: "memory pids\n")
        let found = JobCgroups.discover(selfCgroup: "0::/sandbox/runner\n", mountPoint: mountPoint)
        #expect(found == .available(JobCgroups(jobsDirectory: jobs)))
    }

    @Test func aRunnerCgroupDeeperInTheTreeIsFound() throws {
        let jobs = try makeJobs(under: "system.slice/docker-abc.scope/sandbox", controllers: "cpu memory pids")
        let found = JobCgroups.discover(
            selfCgroup: "0::/system.slice/docker-abc.scope/sandbox/runner\n", mountPoint: mountPoint)
        #expect(found == .available(JobCgroups(jobsDirectory: jobs)))
    }

    @Test func aRunnerThatCannotReadItsCgroupHasNone() {
        #expect(
            JobCgroups.discover(selfCgroup: nil, mountPoint: mountPoint)
                == .unavailable(reason: "cannot read /proc/self/cgroup"))
    }

    @Test func aHostOnCgroupV1HasNone() {
        let v1 = "12:memory:/docker/abc\n11:pids:/docker/abc\n"
        #expect(
            JobCgroups.discover(selfCgroup: v1, mountPoint: mountPoint)
                == .unavailable(reason: "the host does not use cgroup v2"))
    }

    @Test func aRunnerThatDidNotStartThroughThePreStepHasNone() throws {
        try makeJobs(under: "sandbox", controllers: "memory pids")
        guard case .unavailable(let reason) = JobCgroups.discover(selfCgroup: "0::/\n", mountPoint: mountPoint)
        else {
            throw IssueRecorded("a runner in the root cgroup found job cgroups")
        }
        #expect(reason.contains("runner-entrypoint.sh"))
    }

    @Test func aMissingJobsCgroupIsReported() throws {
        guard
            case .unavailable(let reason) = JobCgroups.discover(
                selfCgroup: "0::/sandbox/runner\n", mountPoint: mountPoint)
        else {
            throw IssueRecorded("a missing jobs cgroup was found")
        }
        #expect(reason.hasSuffix("sandbox/jobs does not exist"))
    }

    @Test(arguments: ["", "memory", "pids", "cpu io"])
    func aJobsCgroupWithoutMemoryAndPidsIsReported(controllers: String) throws {
        try makeJobs(under: "sandbox", controllers: controllers)
        guard
            case .unavailable(let reason) = JobCgroups.discover(
                selfCgroup: "0::/sandbox/runner\n", mountPoint: mountPoint)
        else {
            throw IssueRecorded("a jobs cgroup with \(controllers) was accepted")
        }
        #expect(reason.hasPrefix("memory and pids are not enabled"))
    }

    /// The kernel creates a new cgroup's control files. A directory without
    /// them is not a cgroup, so the limits cannot be set, and the directory
    /// must not be left behind.
    @Test func aCgroupWhoseLimitsCannotBeSetIsRemoved() throws {
        let jobs = try makeJobs(under: "sandbox", controllers: "memory pids")
        let cgroups = JobCgroups(jobsDirectory: jobs)
        #expect(throws: JobCgroupError.self) {
            try cgroups.makeJobCgroup(memoryLimitMegabytes: 64, processLimit: 16)
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: jobs.path)
        #expect(left == ["cgroup.subtree_control"])
    }

    @Test func removingACgroupRemovesItsDirectory() async throws {
        let directory = mountPoint.appendingPathComponent("job-test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        await JobCgroup(directory: directory).remove()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Suite struct JobCgroupOutputTests {

    @Test func theOOMKillCountIsReadFromMemoryEvents() {
        let events = "low 0\nhigh 0\nmax 12\noom 2\noom_kill 2\noom_group_kill 0\n"
        #expect(JobCgroup.oomKills(inMemoryEvents: events) == 2)
        #expect(JobCgroup.oomKills(inMemoryEvents: "low 0\noom 0\noom_kill 0\n") == 0)
        #expect(JobCgroup.oomKills(inMemoryEvents: "") == 0)
    }

    @Test func theMemoryLimitMessageNamesTheLimit() {
        #expect(SandboxedScriptRunner.memoryLimitMessage(megabytes: 512).contains("memory limit of 512 MB"))
    }

    private func probeOutput(_ stdout: String, exitCode: Int32 = 0, stderr: String = "") -> ScriptOutput {
        ScriptOutput(exitCode: exitCode, stdout: stdout, stderr: stderr, executionTimeMs: 1, timedOut: false)
    }

    @Test func aProbeInItsCgroupThatSeesItsLimitAndCannotChangeItPasses() {
        let output = probeOutput("0::/sandbox/jobs/job-1\n67108864\n")
        #expect(
            SandboxedScriptRunner.jobCgroupProbeFailure(
                output: output, jobCgroupName: "job-1", memoryLimitBytes: 67_108_864) == nil)
    }

    @Test func aProbeOutsideItsCgroupFails() throws {
        let output = probeOutput("0::/sandbox/runner\n67108864\n")
        let failure = try #require(
            SandboxedScriptRunner.jobCgroupProbeFailure(
                output: output, jobCgroupName: "job-1", memoryLimitBytes: 67_108_864))
        #expect(failure.contains("did not run in its job cgroup"))
    }

    @Test func aProbeThatDoesNotSeeItsLimitFails() throws {
        let output = probeOutput("0::/sandbox/jobs/job-1\nmax\n")
        let failure = try #require(
            SandboxedScriptRunner.jobCgroupProbeFailure(
                output: output, jobCgroupName: "job-1", memoryLimitBytes: 67_108_864))
        #expect(failure.contains("did not see its memory limit"))
    }

    @Test func aProbeThatCanChangeItsLimitFails() throws {
        let output = probeOutput("0::/sandbox/jobs/job-1\n67108864\nwritable\n")
        let failure = try #require(
            SandboxedScriptRunner.jobCgroupProbeFailure(
                output: output, jobCgroupName: "job-1", memoryLimitBytes: 67_108_864))
        #expect(failure.contains("could change its own memory limit"))
    }

    @Test func aProbeThatFailsToStartReportsItsError() {
        let output = probeOutput("", exitCode: 2, stderr: "sh: cannot create cgroup.procs: Permission denied\n")
        #expect(
            SandboxedScriptRunner.jobCgroupProbeFailure(
                output: output, jobCgroupName: "job-1", memoryLimitBytes: 67_108_864)
                == "sh: cannot create cgroup.procs: Permission denied")
    }

    @Test func theSandboxedRunnerTheFlagSelectsCarriesTheMemoryLimitAndTheCgroups() throws {
        let cgroups = JobCgroups(jobsDirectory: URL(fileURLWithPath: "/sys/fs/cgroup/sandbox/jobs"))
        let choice = WorkerCommand.scriptRunner(sandboxed: true, memoryLimitMegabytes: 300, cgroups: cgroups)
        let runner = try #require(choice.runner as? SandboxedScriptRunner)
        #expect(runner.memoryLimitMegabytes == 300)
        #expect(runner.cgroups == cgroups)
    }

    @Test func theDefaultMemoryLimitIsOneGigabyte() {
        #expect(JobCgroups.defaultMemoryLimitMegabytes == 1024)
        #expect(SandboxedScriptRunner().cgroups == nil)
    }
}
