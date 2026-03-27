// Worker/ScriptRunner.swift
//
// Shared subprocess execution for running a single test script. The Worker
// needs prompt timeout handling, full stdout/stderr capture, and Linux
// process-group teardown so child processes do not outlive the runner.

import Foundation
import Subprocess
import SystemPackage

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
protocol ScriptRunner {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput
}

private actor TimeoutState {
    private(set) var timedOut = false

    func markTimedOut() {
        timedOut = true
    }
}

/// Phase 1: direct subprocess execution, no sandbox.
struct UnsandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        let invocation = scriptInvocation(for: script)
        let configuration = configuredSubprocess(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            workDir: workDir,
            isolatesProcessTreeForTimeouts: true
        )

        return await executeScript(
            configuration: configuration,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch script"
        )
    }
}

func executeScript(
    configuration: SubprocessConfiguration,
    timeLimitSeconds: Int,
    launchErrorPrefix: String
) async -> ScriptOutput {
    let start = Date()

    do {
        let timeoutState = TimeoutState()
        let outcome = try await run(
            configuration.executable,
            arguments: configuration.arguments,
            environment: .inherit,
            workingDirectory: configuration.workingDirectory,
            platformOptions: configuration.platformOptions
        ) { execution, _, outputSequence, errorSequence in
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(timeLimitSeconds))
                    await timeoutState.markTimedOut()
                    try execution.send(
                        signal: .terminate,
                        toProcessGroup: configuration.timeoutTargetsProcessGroup
                    )
                    try await Task.sleep(for: .milliseconds(500))
                    try execution.send(
                        signal: .kill,
                        toProcessGroup: configuration.timeoutTargetsProcessGroup
                    )
                } catch {
                    // Process exited before timeout or signal delivery raced with exit.
                }
            }

            async let stdoutData = collectOutput(from: outputSequence)
            async let stderrData = collectOutput(from: errorSequence)
            let result = try await (stdoutData, stderrData)
            timeoutTask.cancel()
            return result
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let timedOut = await timeoutState.timedOut
        return ScriptOutput(
            exitCode: timedOut ? -1 : exitCode(for: outcome.terminationStatus),
            stdout: String(data: outcome.value.0, encoding: .utf8) ?? "",
            stderr: String(data: outcome.value.1, encoding: .utf8) ?? "",
            executionTimeMs: elapsed,
            timedOut: timedOut
        )
    } catch {
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return ScriptOutput(
            exitCode: 2,
            stdout: "",
            stderr: "\(launchErrorPrefix): \(error.localizedDescription)",
            executionTimeMs: elapsed,
            timedOut: false
        )
    }
}

private func collectOutput(from sequence: AsyncBufferSequence) async throws -> Data {
    var data = Data()
    for try await buffer in sequence {
        try buffer.withUnsafeBytes { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }
    return data
}

private func exitCode(for status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code):
        return Int32(code)
    case .signaled(let code):
        return Int32(code)
    }
}

struct SubprocessConfiguration {
    let executable: Executable
    let arguments: Arguments
    let workingDirectory: FilePath
    let platformOptions: PlatformOptions
    let timeoutTargetsProcessGroup: Bool
}

func configuredSubprocess(
    executableURL: URL,
    arguments: [String],
    workDir: URL,
    isolatesProcessTreeForTimeouts: Bool
) -> SubprocessConfiguration {
    var platformOptions = PlatformOptions()
    if isolatesProcessTreeForTimeouts {
        platformOptions.createSession = true
    }

    return SubprocessConfiguration(
        executable: .path(FilePath(executableURL.path)),
        arguments: Arguments(arguments),
        workingDirectory: FilePath(workDir.path),
        platformOptions: platformOptions,
        timeoutTargetsProcessGroup: isolatesProcessTreeForTimeouts
    )
}
