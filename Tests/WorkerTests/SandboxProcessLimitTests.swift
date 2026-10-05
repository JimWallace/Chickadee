// Tests/WorkerTests/SandboxProcessLimitTests.swift
//
// #2224: every job on a runner runs as the same user, so before the process
// limit one job could fork until the container's `pids_limit` was used up, and
// the jobs beside it could not start a process. The sandbox now starts each
// script under its own `RLIMIT_NPROC`, which the kernel counts per user
// namespace. These tests prove that a script starts under its limit and
// cannot raise it; that the runner detects a host where the kernel does not
// apply the limit; and that the container budget warning says what to change.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct JobProcessBudgetTests {

    @Test func theRequiredLimitCoversEveryJobAndTheRunner() {
        let budget = JobProcessBudget(containerLimit: 576, maxJobs: 4, processLimit: 128)
        #expect(budget.required == 4 * 128 + JobProcessBudget.runnerReserve)
        #expect(budget.warning == nil)
    }

    @Test func aContainerLimitBelowTheRequiredOneWarnsWithTheValueToSet() throws {
        let budget = JobProcessBudget(containerLimit: 64, maxJobs: 4, processLimit: 128)
        let warning = try #require(budget.warning)
        #expect(warning.contains("pids_limit to at least 576"))
        #expect(warning.contains("--max-jobs"))
    }

    @Test func theContainerLimitIsReadFromTheFirstReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-pids-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing").path
        let limited = directory.appendingPathComponent("limited").path
        let unlimited = directory.appendingPathComponent("unlimited").path
        try "576\n".write(toFile: limited, atomically: true, encoding: .utf8)
        try "max\n".write(toFile: unlimited, atomically: true, encoding: .utf8)

        #expect(JobProcessBudget.readContainerLimit(paths: [missing, limited]) == 576)
        #expect(JobProcessBudget.readContainerLimit(paths: [unlimited, limited]) == nil)
        #expect(JobProcessBudget.readContainerLimit(paths: [missing]) == nil)
    }

    @Test func theSandboxedRunnerTheFlagSelectsCarriesTheLimit() throws {
        let choice = WorkerCommand.scriptRunner(sandboxed: true, processLimit: 77)
        let runner = try #require(choice.runner as? SandboxedScriptRunner)
        #expect(runner.processLimit == 77)
    }
}

#if os(Linux)
@Suite(.timeLimit(.minutes(2))) final class SandboxProcessLimitTests {

    private let jobDir: URL

    init() throws {
        jobDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sandbox-nproc-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("chickadee_ts_job_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: jobDir.deletingLastPathComponent())
    }

    private func writeScript(_ body: String) throws -> URL {
        let script = jobDir.appendingPathComponent("test.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: script.path)
        return script
    }

    /// The script starts under the limit, soft and hard, with the sandbox's
    /// own two processes added, and cannot raise it: that needs
    /// `CAP_SYS_RESOURCE` outside its user namespace, which even a sandbox
    /// that root starts does not have. Read from the script's own
    /// `/proc/self/limits`, so this holds as root, where the CI runs.
    ///
    /// That the kernel then counts only this namespace's processes against
    /// the limit, so that a script beside it as the same user is unaffected,
    /// is the kernel's per-user-namespace `RLIMIT_NPROC` accounting (Linux
    /// 5.14 and later). It was shown by hand as `nobody`, and
    /// `processLimitIsEnforced` checks it at every runner start. A test of it
    /// needs a non-root user namespace, which the CI host's AppArmor refuses.
    @Test(.requiresSandbox) func theScriptStartsUnderItsLimitAndCannotRaiseIt() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            grep 'Max processes' /proc/self/limits
            if prlimit --pid $$ --nproc=100000:100000 2>/dev/null; then echo "raised"; fi
            """)
        let output = await SandboxedScriptRunner(processLimit: 16)
            .run(script: script, workDir: jobDir, timeLimitSeconds: 30)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        let fields = output.stdout.split(separator: "\n").first?.split(separator: " ").map(String.init) ?? []
        let limits = fields.filter { Int($0) != nil }
        #expect(limits == ["18", "18"], "limits line: \(output.stdout)")
        #expect(!output.stdout.contains("raised"))
    }

    @Test(.requiresSandbox) func theProbeReportsWhetherTheKernelAppliesTheLimit() async {
        // The kernel applies the limit to a sandbox that a non-root runner
        // starts, and not to one that root starts.
        let enforced = await SandboxedScriptRunner.processLimitIsEnforced(
            workDir: jobDir.deletingLastPathComponent())
        #expect(enforced == (getuid() != 0))
    }

    @Test(.requiresSandbox) func aScriptWithinItsLimitIsUnaffected() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            for i in 1 2 3 4 5; do sleep 0.1 & done
            wait
            echo done
            """)
        let output = await SandboxedScriptRunner(processLimit: 8)
            .run(script: script, workDir: jobDir, timeLimitSeconds: 30)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("done"))
    }
}
#endif
