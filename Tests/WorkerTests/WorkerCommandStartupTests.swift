// Tests/WorkerTests/WorkerCommandStartupTests.swift
//
// The startup decisions of `WorkerCommand` that the mutation sweep of
// 2026-10-13 (#2535) changed without a test noticing. Each one is reached
// through the parsed command, so the flag a test names is the flag the
// operator types. Where `run()` was the only caller, the rule moved into a
// function the test can call: `processInspectionStatus`, `workerSecretFlagUse`
// and `memoryBudgetWarning`.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import ArgumentParser
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct WorkerCommandStartupTests {

    private static func temporaryWorkRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - process_inspection

    /// Survivors `:86 RelationalOperatorReplacement` (`== 0` to `!= 0`) and
    /// `:190 SwapTernary`. Both inverted the `process_inspection` field, so
    /// the startup log said `allowed` on the host that refused inspection,
    /// and an operator reading the log for the secret-leak check would have
    /// read the opposite of the truth.
    @Test func theInspectionLabelFollowsTheReturnCode() {
        #expect(WorkerCommand.processInspectionStatus(0) == "refused")
        #expect(WorkerCommand.processInspectionStatus(-1) == "allowed")
        #expect(WorkerCommand.processInspectionStatus(1) == "allowed")
    }

    // MARK: - --worker-secret

    /// Survivor `:88 RelationalOperatorReplacement` (`workerSecret != nil` to
    /// `== nil`). The flag read as set when it was absent, so every sandboxed
    /// runner without `--worker-secret` would have refused to start, and
    /// every unsandboxed one would have warned about a flag nobody passed.
    @Test func theFlagUseComesFromTheParsedFlag() throws {
        #expect(try WorkerCommand.parse([]).workerSecretFlagUse == .notUsed)
        #expect(try WorkerCommand.parse(["--sandbox"]).workerSecretFlagUse == .notUsed)

        guard case .deprecated = try WorkerCommand.parse(["--worker-secret", "s"]).workerSecretFlagUse else {
            Issue.record("--worker-secret without --sandbox did not warn")
            return
        }
        guard case .refused = try WorkerCommand.parse(["--worker-secret", "s", "--sandbox"]).workerSecretFlagUse
        else {
            Issue.record("--worker-secret with --sandbox was not refused")
            return
        }
    }

    // MARK: - The job limits

    /// Survivors `:244`, `:247` and `:250 RelationalOperatorReplacement`
    /// (`>= 1` to `<= 1`). A limit of 0 would have passed and the default
    /// limits would have been refused, so no runner could start at all.
    @Test(arguments: ["--job-process-limit", "--job-disk-limit", "--job-memory-limit"])
    func aLimitBelowOneIsRefusedWithItsName(flag: String) async throws {
        let workRoot = try Self.temporaryWorkRoot()
        defer { try? FileManager.default.removeItem(at: workRoot) }
        let command = try WorkerCommand.parse([flag, "0"])
        let capture = RunnerLogCapture()
        await #expect(throws: ExitCode.failure) {
            try await RunnerLogCapture.$current.withValue(capture) {
                _ = try await command.checkSandbox(workRoot: workRoot)
            }
        }
        #expect(capture.capturedLines == ["Error: \(flag) must be at least 1"])
    }

    @Test func theDefaultLimitsPassAndAnUnsandboxedRunnerChecksNothingElse() async throws {
        let workRoot = try Self.temporaryWorkRoot()
        defer { try? FileManager.default.removeItem(at: workRoot) }
        let check = try await WorkerCommand.parse([]).checkSandbox(workRoot: workRoot)
        #expect(check.processLimitEnforced == false)
        #expect(check.cgroups == nil)
        #expect(check.cgroupsStatus == "not sandboxed")
    }

    // MARK: - The startup log fields

    private static let cgroups = JobCgroups(
        jobsDirectory: URL(fileURLWithPath: "/sys/fs/cgroup/sandbox/jobs", isDirectory: true))

    /// Survivors `:290` and `:292 SwapTernary`, and `:294
    /// RelationalOperatorReplacement` with `:294 SwapTernary`. Each one made
    /// the startup log report a limit as `none` where it applied, or a value
    /// where it did not; a runner would have graded under limits its log
    /// denied having.
    @Test func withTheSandboxEveryLimitIsReportedWithItsValue() throws {
        let command = try WorkerCommand.parse([
            "--sandbox", "--job-process-limit", "7", "--job-disk-limit", "9", "--job-memory-limit", "11",
        ])
        let fields = command.jobLimitLogFields(
            WorkerCommand.SandboxCheck(processLimitEnforced: true, cgroups: Self.cgroups, cgroupsStatus: "enabled"))
        #expect(fields["job_process_limit"] as? String == "7")
        #expect(fields["job_process_limit_enforced"] as? Bool == true)
        #expect(fields["job_disk_limit_mb"] as? String == "9")
        #expect(fields["job_cgroups"] as? String == "enabled")
        #expect(fields["job_memory_limit_mb"] as? String == "11")
    }

    @Test func withoutTheSandboxEveryLimitIsReportedAsNone() throws {
        let command = try WorkerCommand.parse(["--job-process-limit", "7", "--job-disk-limit", "9"])
        let fields = command.jobLimitLogFields(
            WorkerCommand.SandboxCheck(processLimitEnforced: false, cgroups: nil, cgroupsStatus: "not sandboxed"))
        #expect(fields["job_process_limit"] as? String == "none")
        #expect(fields["job_disk_limit_mb"] as? String == "none")
        #expect(fields["job_memory_limit_mb"] as? String == "none")
    }

    // MARK: - The memory budget

    /// Survivor `:276 RelationalOperatorReplacement` (`cgroups != nil` to
    /// `== nil`). The container memory budget would have been checked on the
    /// runner that applies no memory limit, and skipped on the one that does.
    @Test func theMemoryBudgetIsCheckedOnlyWithTheJobCgroups() throws {
        let tooSmall = 256 * 1024 * 1024
        #expect(
            WorkerCommand.memoryBudgetWarning(
                cgroups: nil, containerLimitBytes: tooSmall, maxJobs: 4, memoryLimitMegabytes: 1024) == nil)
        #expect(
            WorkerCommand.memoryBudgetWarning(
                cgroups: Self.cgroups, containerLimitBytes: nil, maxJobs: 4, memoryLimitMegabytes: 1024) == nil)
        let warning = try #require(
            WorkerCommand.memoryBudgetWarning(
                cgroups: Self.cgroups, containerLimitBytes: tooSmall, maxJobs: 4, memoryLimitMegabytes: 1024))
        #expect(warning.contains("--job-memory-limit"))
    }

    // MARK: - The cgroups warning

    /// Survivor `:313 RemoveSideEffects`: the warning that the job cgroups
    /// are unavailable was deleted and nothing failed. Without it an operator
    /// has a runner whose `--job-memory-limit` does nothing, and the startup
    /// log's `job_cgroups` field is the only other trace. Shaped by the host:
    /// where the runner has its job cgroups the warning must not appear.
    @Test func aRunnerWithoutJobCgroupsWarnsOnce() async throws {
        let workRoot = try Self.temporaryWorkRoot()
        defer { try? FileManager.default.removeItem(at: workRoot) }
        let capture = RunnerLogCapture()
        let (cgroups, status) = await RunnerLogCapture.$current.withValue(capture) {
            await WorkerCommand.checkJobCgroups(workRoot: workRoot)
        }
        let warnings = capture.capturedLines.filter { $0.hasPrefix("Warning: job cgroups are unavailable") }
        if cgroups == nil {
            #expect(status.hasPrefix("unavailable: "))
            #expect(warnings.count == 1)
            #expect(try #require(warnings.first).contains("runner-entrypoint.sh"))
        } else {
            #expect(status == "enabled")
            #expect(warnings.isEmpty)
        }
    }
}

/// `drainOnTerminate` changes process-wide signal state, so each test runs in
/// a child process. Survivors `:217`, `:219` and `:220 RemoveSideEffects`:
/// deleting `signal(SIGTERM, SIG_IGN)`, the handler, or `resume()` each left
/// a runner that `docker stop` kills with its running jobs, which is the
/// defect the function exists to fix, and nothing failed.
///
/// What `SIG_IGN` is for, measured on Linux: once the source has registered,
/// libdispatch has installed its own handler and the process survives SIGTERM
/// with or without it. Before that, a SIGTERM takes the default action and
/// stops the process, unless the signal is ignored. In a cold process that
/// window is real (a `kill` right after `resume()` was lost 3 of 3 times, one
/// 50 ms later delivered 3 of 3); in the exit-test child the manager thread is
/// warm and the source has registered before `drainOnTerminate` returns, so
/// no test here can send a signal into the window. The ignore is therefore
/// pinned where it is observable: on `terminateSource(draining:)`, before the
/// source is resumed.
@Suite(.timeLimit(.minutes(1))) struct WorkerCommandTerminateTests {

    private struct NoJobPoller: JobPolling {
        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? { nil }
    }

    private struct HealthyReporter: Reporting {
        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
    }

    /// Whether `source` registers within `seconds`. libdispatch invokes the
    /// registration handler at once when the registration already happened.
    /// Bounded, because a source that is never resumed never registers, and
    /// an unbounded wait here hangs the child, and the whole test run, rather
    /// than failing it.
    private static func registers(_ source: any DispatchSourceSignal, within seconds: Double) -> Bool {
        let registered = DispatchSemaphore(value: 0)
        source.setRegistrationHandler { registered.signal() }
        return registered.wait(timeout: .now() + seconds) == .success
    }

    @Test func sigtermDrainsTheRunnerAndDoesNotStopIt() async {
        await #expect(processExitsWith: .success) {
            guard let apiBaseURL = URL(string: "http://127.0.0.1:9") else { exit(3) }
            let daemon = WorkerDaemon(
                poller: NoJobPoller(), reporter: HealthyReporter(), runner: UnsandboxedScriptRunner(),
                apiBaseURL: apiBaseURL, workerID: "terminate", workerSecret: "secret", maxConcurrentJobs: 1)
            let source = WorkerCommand.drainOnTerminate(daemon)
            defer { source.cancel() }
            // The source registers on the manager queue after `resume()`, and a
            // signal that arrives before that is dropped by `SIG_IGN`. Measured:
            // a kill right after `resume()` was lost 3 of 3 times, and one 50 ms
            // later was delivered 3 of 3. The registration handler is the
            // deterministic way to wait for it.
            guard Self.registers(source, within: 5) else { exit(2) }
            kill(getpid(), SIGTERM)
            for _ in 0..<400 {
                if await daemon.isDraining { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            exit(1)
        }
    }

    /// Survivor `:217`. The source is handed back ignoring SIGTERM, before it
    /// is resumed. The child inherits SIGTERM at its default disposition
    /// (measured), so a deleted `signal(SIGTERM, SIG_IGN)` reads as `SIG_DFL`.
    @Test func theTerminateSourceIgnoresSigtermBeforeItIsResumed() async {
        await #expect(processExitsWith: .success) {
            guard let apiBaseURL = URL(string: "http://127.0.0.1:9") else { exit(3) }
            let daemon = WorkerDaemon(
                poller: NoJobPoller(), reporter: HealthyReporter(), runner: UnsandboxedScriptRunner(),
                apiBaseURL: apiBaseURL, workerID: "terminate-source", workerSecret: "secret", maxConcurrentJobs: 1)
            let source = WorkerCommand.terminateSource(draining: daemon)
            var action = sigaction()
            sigaction(SIGTERM, nil, &action)
            let ignored = unsafeBitCast(action.__sigaction_handler.sa_handler, to: Int.self) == 1
            // A source that is released while suspended traps, so resume it
            // before it goes away.
            source.resume()
            source.cancel()
            guard ignored else { exit(1) }
        }
    }
}
