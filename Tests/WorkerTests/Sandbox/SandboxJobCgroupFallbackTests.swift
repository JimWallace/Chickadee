// Tests/WorkerTests/Sandbox/SandboxJobCgroupFallbackTests.swift
//
// What `SandboxedScriptRunner` does when it has job cgroups but cannot create
// one for a command, and what `jobCgroupProbe` reports before it launches
// anything. The 2026-11 coverage report showed both with no hits: every
// earlier sandbox test ran without cgroups, and the cgroup tests stopped at
// `JobCgroups` itself.
//
// The rule under test (SandboxedScriptRunner.swift, `inJobCgroup`): a job is
// graded rather than failed for a fault of the runner's. When the cgroup
// cannot be made, the command runs without one and the runner logs why.
//
// A `JobCgroups` here points at an ordinary directory, not at cgroupfs. The
// runner can create a directory there, but not open the `memory.max` that the
// kernel would have made, so `makeJobCgroup` fails the way it fails on a host
// whose delegation broke after startup. The success path needs a delegated
// cgroup v2 tree, which no test host has.

import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) final class SandboxJobCgroupFallbackTests {

    /// The work root; the job directory is its child, as the runner lays it out.
    private let workRoot: URL
    private let jobDir: URL
    /// An ordinary directory that stands in for the delegated `jobs` cgroup.
    private let fakeJobsDirectory: URL

    init() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cgroup-fallback-\(UUID().uuidString)", isDirectory: true)
        jobDir = workRoot.appendingPathComponent("chickadee_ts_\(UUID().uuidString)", isDirectory: true)
        fakeJobsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-fake-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeJobsDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workRoot)
        try? FileManager.default.removeItem(at: fakeJobsDirectory)
    }

    private var missingJobsDirectory: URL {
        fakeJobsDirectory.appendingPathComponent("absent/jobs", isDirectory: true)
    }

    private func writeScript(_ body: String) throws -> URL {
        let url = jobDir.appendingPathComponent("test.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return url
    }

    /// The `error` field of each `job_cgroup_unavailable` line.
    private static func cgroupErrors(in capture: RunnerLogCapture) -> [String] {
        capture.capturedLines.compactMap { line in
            guard let payload = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                payload["event"] as? String == "job_cgroup_unavailable"
            else { return nil }
            return payload["error"] as? String
        }
    }

    // MARK: - A cgroup that cannot be created

    @Test(.requiresSandbox) func aScriptWhoseCgroupCannotBeCreatedIsStillGraded() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            echo '{"score": 0.5, "shortResult": "half"}'
            echo "graded" >&2
            exit 1
            """)
        let runner = SandboxedScriptRunner(cgroups: JobCgroups(jobsDirectory: missingJobsDirectory))
        let capture = RunnerLogCapture()
        let output = await RunnerLogCapture.$current.withValue(capture) {
            await runScriptRobustly(runner, script: script, workDir: jobDir, timeLimitSeconds: 30)
        }
        #expect(output.exitCode == 1, "stderr: \(output.stderr)")
        #expect(output.stdout.contains(#""shortResult": "half""#))
        #expect(output.stderr.contains("graded"))
        #expect(!output.timedOut)
        let errors = Self.cgroupErrors(in: capture)
        let expectedPrefix = "cannot create \(missingJobsDirectory.path)/job-"
        #expect(errors.isEmpty == false)
        #expect(errors.allSatisfy { $0.hasPrefix(expectedPrefix) }, "\(errors)")
    }

    /// The make step goes through the same fallback. A cgroup directory that
    /// was created but whose limits could not be set is removed, so a broken
    /// delegation does not leave one directory behind per command.
    @Test(.requiresSandbox) func aCommandWhoseCgroupLimitsCannotBeSetRunsAndLeavesNoCgroup() async throws {
        let runner = SandboxedScriptRunner(
            memoryLimitMegabytes: 64, cgroups: JobCgroups(jobsDirectory: fakeJobsDirectory))
        let capture = RunnerLogCapture()
        let workDir = jobDir
        let output = await RunnerLogCapture.$current.withValue(capture) {
            await withSubprocessSlot {
                await runner.run(
                    command: "/bin/sh", arguments: ["-c", "echo built"], workDir: workDir,
                    timeLimitSeconds: 30, launchErrorPrefix: "Failed to launch make")
            }
        }
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("built"))
        let errors = Self.cgroupErrors(in: capture)
        #expect(errors.count == 1)
        #expect(try #require(errors.first).contains("memory.max"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fakeJobsDirectory.path).isEmpty)
    }

    // MARK: - jobCgroupProbe before launch

    /// The probe reports, rather than throws, a cgroup it cannot create. The
    /// runner then grades without job cgroups and says why at startup.
    @Test func theProbeReportsACgroupItCannotCreate() async throws {
        let reason = await SandboxedScriptRunner.jobCgroupProbe(
            cgroups: JobCgroups(jobsDirectory: missingJobsDirectory), workDir: workRoot)
        #if os(Linux)
        #expect(try #require(reason).hasPrefix("cannot create \(missingJobsDirectory.path)/job-"))
        // The probe directory it made in the work root is gone again.
        let left = try FileManager.default.contentsOfDirectory(atPath: workRoot.path)
        #expect(left == [jobDir.lastPathComponent], "\(left)")
        #else
        #expect(reason == "job cgroups need Linux")
        #endif
    }

    @Test func theProbeReportsAWorkRootItCannotWrite() async throws {
        let missingRoot = workRoot.appendingPathComponent("absent", isDirectory: true)
        let reason = await SandboxedScriptRunner.jobCgroupProbe(
            cgroups: JobCgroups(jobsDirectory: fakeJobsDirectory), workDir: missingRoot)
        #if os(Linux)
        #expect(reason == "cannot write to the work root \(missingRoot.path)")
        #else
        #expect(reason == "job cgroups need Linux")
        #endif
    }
}
