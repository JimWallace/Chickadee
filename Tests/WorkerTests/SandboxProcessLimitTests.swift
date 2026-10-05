// Tests/WorkerTests/SandboxProcessLimitTests.swift
//
// #2224: every job on a runner runs as the same user, so before the process
// limit one job could fork until the container's `pids_limit` was used up, and
// the jobs beside it could not start a process. The sandbox now starts each
// script under its own `RLIMIT_NPROC`, which the kernel counts per user
// namespace. These tests prove that one script stops at its limit while a
// script beside it, as the same user, still starts its processes; that the
// runner detects a host where the limit is not applied; and that the
// container budget warning says what to change.
//
// The kernel does not apply `RLIMIT_NPROC` to a sandbox that root starts, and
// the CI runs as root. So the isolation test starts the real sandbox launch as
// `nobody` through `setpriv`, as a production runner runs as `chickadee`.

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

    /// A work root with two job directories, as the runner lays them out. Both
    /// are writable by `nobody`, who runs the sandboxes when the test is root.
    private let workRoot: URL
    private let forkingJob: URL
    private let neighbourJob: URL

    init() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sandbox-nproc-\(UUID().uuidString)", isDirectory: true)
        forkingJob = workRoot.appendingPathComponent("chickadee_ts_fork_\(UUID().uuidString)", isDirectory: true)
        neighbourJob = workRoot.appendingPathComponent("chickadee_ts_next_\(UUID().uuidString)", isDirectory: true)
        for directory in [forkingJob, neighbourJob] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o777)], ofItemAtPath: directory.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: workRoot.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: workRoot)
    }

    /// The real sandbox launch for a shell command, started as `nobody` when
    /// the test runs as root.
    private func launch(_ command: String, in workDir: URL, processLimit: Int) -> ScriptLaunch {
        let sandboxed = sandboxWrap(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            workDir: workDir,
            environment: mergedScriptEnvironment(overrides: [:]),
            processLimit: processLimit)
        guard getuid() == 0 else { return sandboxed }
        return ScriptLaunch(
            executablePath: "/usr/bin/setpriv",
            arguments: ["--reuid=65534", "--regid=65534", "--clear-groups", sandboxed.executablePath]
                + sandboxed.arguments,
            env: sandboxed.env)
    }

    @Test(.requiresSandbox) func aForkingScriptStopsAtItsLimitAndTheScriptBesideItStillStartsItsProcesses()
        async throws
    {
        // Each background `sleep` is one process. The forking script prints how
        // many it has started; the shell ends with "Cannot fork" at the limit.
        let forking = launch(
            """
            n=0
            while [ "$n" -lt 200 ]; do
                sleep 4 &
                n=$((n+1))
                echo "$n"
            done
            """,
            in: forkingJob, processLimit: 16)
        // Starts after the forking script has reached its limit, as the same
        // user, while the forking script's processes are still running.
        let neighbour = launch(
            """
            sleep 1
            n=0
            while [ "$n" -lt 10 ]; do
                sleep 1 &
                n=$((n+1))
            done
            wait
            echo "started $n"
            """,
            in: neighbourJob, processLimit: 16)

        let forkingDir = forkingJob
        let neighbourDir = neighbourJob
        async let forkingOutput = executeScriptLaunch(
            forking, workDir: forkingDir, timeLimitSeconds: 30, launchErrorPrefix: "fork test")
        async let neighbourOutput = executeScriptLaunch(
            neighbour, workDir: neighbourDir, timeLimitSeconds: 30, launchErrorPrefix: "neighbour test")
        let (forked, beside) = await (forkingOutput, neighbourOutput)

        let started = forked.stdout.split(separator: "\n").last.map(String.init)
        #expect(started == "16", "processes started: \(started ?? "none"), stderr: \(forked.stderr)")
        #expect(forked.exitCode != 0)
        #expect(beside.exitCode == 0, "stderr: \(beside.stderr)")
        #expect(beside.stdout.contains("started 10"))
    }

    @Test(.requiresSandbox) func theProbeReportsWhetherTheKernelAppliesTheLimit() async {
        // The kernel applies the limit to a sandbox that a non-root runner
        // starts, and not to one that root starts.
        let enforced = await SandboxedScriptRunner.processLimitIsEnforced(workDir: workRoot)
        #expect(enforced == (getuid() != 0))
    }

    @Test(.requiresSandbox) func aScriptWithinItsLimitIsUnaffected() async throws {
        let script = forkingJob.appendingPathComponent("test.sh")
        try """
        #!/bin/sh
        for i in 1 2 3 4 5; do sleep 0.1 & done
        wait
        echo done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: script.path)
        let output = await SandboxedScriptRunner(processLimit: 8)
            .run(script: script, workDir: forkingJob, timeLimitSeconds: 30)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("done"))
    }
}
#endif
