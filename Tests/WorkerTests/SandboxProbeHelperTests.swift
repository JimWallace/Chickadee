// Tests/WorkerTests/SandboxProbeHelperTests.swift
//
// The two rules the sandbox probes share, pulled out of the probes so a test
// can reach them without a sandbox. The mutation sweep of 2026-10-13 (#2535)
// changed each one and nothing failed:
//
//   * `probe` inverted its exit-code check (`:271`) and swapped its two
//     failure messages (`:273`). The inversion is the trap worth recording: a
//     probe that fails where the sandbox works makes `sandboxIsAvailable()`
//     false, so every `.requiresSandbox` test, the one test of `probe`
//     included, skipped -- and the mutant that broke the trait survived
//     because of the trait.
//   * `processLimitIsEnforced` (`:290`) and `jobCgroupProbe` (`:330`) each
//     inverted the check that their probe directory was created. On a runner
//     that runs as root the kernel applies no process limit either way, so
//     the probe's answer did not change, and the cgroup probe needs the
//     delegation only the image build has.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct SandboxProbeHelperTests {

    private static func output(exitCode: Int32, stderr: String) -> ScriptOutput {
        ScriptOutput(exitCode: exitCode, stdout: "", stderr: stderr, executionTimeMs: 1, timedOut: false)
    }

    @Test func aProbeThatExitsZeroPassed() {
        #expect(SandboxedScriptRunner.probeFailure(output: Self.output(exitCode: 0, stderr: "")) == nil)
        #expect(SandboxedScriptRunner.probeFailure(output: Self.output(exitCode: 0, stderr: "noise")) == nil)
    }

    @Test func aFailedProbeReportsItsComplaintOrItsExitCode() {
        #expect(
            SandboxedScriptRunner.probeFailure(output: Self.output(exitCode: 1, stderr: "the sandbox did not hide x\n"))
                == "the sandbox did not hide x")
        #expect(
            SandboxedScriptRunner.probeFailure(output: Self.output(exitCode: 127, stderr: " \n"))
                == "probe exited with code 127")
    }

    @Test func aProbeDirectoryIsCreatedUnderAWritableWorkRoot() throws {
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-probe-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let probeDir = try #require(SandboxedScriptRunner.makeProbeDirectory(in: workRoot))
        #expect(
            (try? probeDir.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
        #expect(probeDir.deletingLastPathComponent().standardizedFileURL == workRoot.standardizedFileURL)
    }

    @Test func noProbeDirectoryIsCreatedUnderAMissingWorkRoot() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-root-\(UUID().uuidString)", isDirectory: true)
        #expect(SandboxedScriptRunner.makeProbeDirectory(in: missing) == nil)
    }
}
