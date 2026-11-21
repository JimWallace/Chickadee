// Tests/WorkerTests/WorkerCommandRunTests.swift
//
// `WorkerCommand.run()` end to end, and the sandbox half of
// `checkSandbox(workRoot:)`. The 2026-11 coverage report showed `run()` and the
// sandbox-on checks with no hits at all: `WorkerCommandStartupTests` reaches
// each startup rule through the function it moved into, never through the
// command an operator starts.
//
// `run()` refuses process inspection for the whole process, reads the
// environment and installs a SIGTERM handler, so each `run()` test is an exit
// test: the body runs in a child process of the test runner, and nothing it
// changes reaches another test.

import ArgumentParser
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct WorkerCommandRunTests {

    // MARK: - run()

    /// An API base URL that does not parse is refused before the runner
    /// creates its work root or reads its secret, and the refusal names the
    /// flag and the value.
    @Test func anInvalidAPIBaseURLIsRefusedWithTheFlagName() async {
        await #expect(processExitsWith: .success) {
            var command = try WorkerCommand.parse(["--api-base-url", "", "--no-sandbox"])
            let capture = RunnerLogCapture()
            do {
                try await RunnerLogCapture.$current.withValue(capture) { try await command.run() }
                exit(10)
            } catch let code as ExitCode {
                guard code == .failure else { exit(11) }
            }
            guard capture.capturedLines == ["Error: invalid --api-base-url ''"] else {
                FileHandle.standardError.write(Data(capture.capturedLines.joined(separator: "\n").utf8))
                exit(12)
            }
        }
    }

    /// With no `RUNNER_SHARED_SECRET` and no `.worker-secret` file, the runner
    /// refuses to start rather than poll unsigned. It has already created its
    /// work root at `--test-setup-cache-dir`, which the refusal leaves in place.
    @Test(
        .enabled(
            if: !FileManager.default.fileExists(atPath: "/data/.worker-secret"),
            "a /data/.worker-secret on this host would supply the secret"))
    func aRunnerWithoutASecretRefusesToStart() async {
        await #expect(processExitsWith: .success) {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("chickadee-run-nosecret-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let workRoot = scratch.appendingPathComponent("cache/nested", isDirectory: true)
            // The secret file is looked for in the working directory, so the
            // child moves to an empty one. C strings, so `unsafe`.
            guard FileManager.default.changeCurrentDirectoryPath(scratch.path) else { exit(20) }
            unsafe unsetenv("RUNNER_SHARED_SECRET")
            unsafe setenv("RUNNER_CAPABILITY_DISCOVERY_ENABLED", "false", 1)
            var command = try WorkerCommand.parse([
                "--api-base-url", "http://127.0.0.1:9", "--no-sandbox", "--test-setup-cache-dir", workRoot.path,
            ])
            let capture = RunnerLogCapture()
            do {
                try await RunnerLogCapture.$current.withValue(capture) { try await command.run() }
                exit(21)
            } catch let code as ExitCode {
                guard code == .failure else { exit(22) }
            }
            guard capture.capturedLines == ["Error: missing runner secret. Set RUNNER_SHARED_SECRET."] else {
                FileHandle.standardError.write(Data(capture.capturedLines.joined(separator: "\n").utf8))
                exit(23)
            }
            guard (try? workRoot.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                exit(24)
            }
        }
    }

    /// A runner with a secret starts, logs its configuration as the flags set
    /// it, and drains on SIGTERM: `run()` returns and the shutdown log says
    /// `drained`. The API server address refuses connections, so the slots
    /// only back off; no job runs.
    ///
    /// A SIGTERM while the signal still has its default action would stop the
    /// child, so the child sends one only once `run()` has taken the default
    /// away, and keeps sending until the runner drains: one that arrives
    /// before the signal source registers is dropped, and `drain()` ignores a
    /// repeat. "Taken away", not "ignored": on Linux, libdispatch replaces
    /// `SIG_IGN` with its own handler when the source registers, so a check
    /// for `SIG_IGN` stops sending at the moment a signal would drain.
    @Test func aStartedRunnerLogsItsConfigurationAndDrainsOnSigterm() async {
        await #expect(processExitsWith: .success) {
            let workRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("chickadee-run-drain-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workRoot) }
            unsafe setenv("RUNNER_SHARED_SECRET", "run-test-secret", 1)
            unsafe setenv("RUNNER_CAPABILITY_DISCOVERY_ENABLED", "false", 1)
            var command = try WorkerCommand.parse([
                "--api-base-url", "http://127.0.0.1:9", "--worker-id", "run-test", "--max-jobs", "2",
                "--no-sandbox", "--test-setup-cache-dir", workRoot.path,
            ])
            let terminator = Task.detached {
                for _ in 0..<1200 {
                    if WorkerCommandRunTests.sigtermHasLostItsDefaultAction() { kill(getpid(), SIGTERM) }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                FileHandle.standardError.write(Data("the runner did not drain\n".utf8))
                exit(30)
            }
            let capture = RunnerLogCapture()
            try await RunnerLogCapture.$current.withValue(capture) { try await command.run() }
            terminator.cancel()
            let payloads = capture.capturedLines.compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            func payload(_ event: String) -> [String: Any]? {
                payloads.first { $0["event"] as? String == event }
            }
            guard let configuration = payload("runner_configuration"),
                configuration["runner_id"] as? String == "run-test",
                configuration["api_base_url"] as? String == "http://127.0.0.1:9",
                configuration["max_jobs"] as? Int == 2,
                configuration["sandbox_mode"] as? String == "unsandboxed",
                configuration["test_setup_cache_dir"] as? String == workRoot.path,
                configuration["job_process_limit"] as? String == "none",
                configuration["job_cgroups"] as? String == "not sandboxed",
                ["refused", "allowed"].contains(configuration["process_inspection"] as? String)
            else {
                FileHandle.standardError.write(Data(capture.capturedLines.joined(separator: "\n").utf8))
                exit(31)
            }
            guard payload("runner_startup")?["status"] as? String == "starting",
                payload("runner_shutdown")?["status"] as? String == "drained",
                payload("runner_profile_detected") == nil
            else {
                FileHandle.standardError.write(Data(capture.capturedLines.joined(separator: "\n").utf8))
                exit(32)
            }
        }
    }

    /// Whether SIGTERM no longer has its default action (`SIG_DFL`, 0) in this
    /// process: it is ignored (macOS, and Linux before the source registers)
    /// or handled (Linux, by libdispatch, after). `sigaction` holds a C union
    /// and takes a pointer, so the read is `unsafe`.
    fileprivate static func sigtermHasLostItsDefaultAction() -> Bool {
        var action = sigaction()
        unsafe sigaction(SIGTERM, nil, &action)
        #if canImport(Darwin)
        return unsafe unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) != 0
        #else
        return unsafe unsafeBitCast(action.__sigaction_handler.sa_handler, to: Int.self) != 0
        #endif
    }

    // MARK: - checkSandbox with the sandbox on

    /// With the sandbox on, a work root the probe cannot use is a refusal to
    /// start, and the message says how to run without the sandbox.
    @Test func aSandboxThatCannotStartIsARefusal() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-run-missing-\(UUID().uuidString)", isDirectory: true)
        let command = try WorkerCommand.parse(["--sandbox"])
        let capture = RunnerLogCapture()
        await #expect(throws: ExitCode.failure) {
            try await RunnerLogCapture.$current.withValue(capture) {
                _ = try await command.checkSandbox(workRoot: missing)
            }
        }
        let message = try #require(capture.capturedLines.first)
        #expect(capture.capturedLines.count == 1)
        #expect(message.hasPrefix("Error: the sandbox is on, but this host cannot start the sandbox: "))
        #expect(message.contains(SandboxedScriptRunner.probeFailureAdvice))
    }

    /// Where the sandbox works, the check passes. Its report agrees with the
    /// warnings it wrote: the process-limit warning appears exactly when the
    /// limit is not enforced, and the job cgroups are reported as enabled
    /// exactly when they are returned.
    @Test(.requiresSandbox) func aWorkingSandboxPassesAndWarnsOnlyAboutWhatItLacks() async throws {
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-run-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }
        let command = try WorkerCommand.parse(["--sandbox", "--job-process-limit", "64"])
        let capture = RunnerLogCapture()
        let check = try await RunnerLogCapture.$current.withValue(capture) {
            try await command.checkSandbox(workRoot: workRoot)
        }
        let lines = capture.capturedLines
        #expect(!lines.contains { $0.hasPrefix("Error:") }, "\(lines)")
        let processWarnings = lines.filter { $0.hasPrefix("Warning: --job-process-limit is not enforced") }
        #expect(processWarnings.count == (check.processLimitEnforced ? 0 : 1), "\(lines)")
        if check.cgroups == nil {
            #expect(check.cgroupsStatus.hasPrefix("unavailable: "))
        } else {
            #expect(check.cgroupsStatus == "enabled")
        }
        let fields = command.jobLimitLogFields(check)
        #expect(fields["job_process_limit"] as? String == "64")
        #expect(fields["job_process_limit_enforced"] as? Bool == check.processLimitEnforced)
        #expect(fields["job_cgroups"] as? String == check.cgroupsStatus)
    }
}
