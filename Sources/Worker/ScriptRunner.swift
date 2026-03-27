// Worker/ScriptRunner.swift
//
// Protocol and Phase 1 (unsandboxed) implementation for running a single
// test script subprocess. Phase 4 will add SandboxedScriptRunner conforming
// to the same protocol without changing any callers.

import Foundation

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
protocol ScriptRunner {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput
}

struct ProcessLaunchConfiguration {
    let usesSeparateProcessGroup: Bool
    let usesExternalTimeout: Bool
}

private final class CapturedPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

func executeScriptProcess(
    _ proc: Process,
    timeLimitSeconds: Int,
    launchErrorPrefix: String,
    usesSeparateProcessGroup: Bool,
    usesExternalTimeout: Bool
) async -> ScriptOutput {
    let start = Date()

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutBuffer = CapturedPipeBuffer()
    let stderrBuffer = CapturedPipeBuffer()

    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe
    installPipeCapture(for: stdoutPipe, buffer: stdoutBuffer)
    installPipeCapture(for: stderrPipe, buffer: stderrBuffer)

    do {
        try proc.run()
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

    var timedOut = false
    let timeoutItem: DispatchWorkItem?
    if usesExternalTimeout {
        timeoutItem = nil
    } else {
        let workItem = DispatchWorkItem {
            guard proc.isRunning else { return }
            timedOut = true
            terminateScriptProcess(proc, usesSeparateProcessGroup: usesSeparateProcessGroup)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeLimitSeconds),
            execute: workItem
        )
        timeoutItem = workItem
    }

    proc.waitUntilExit()
    timeoutItem?.cancel()

    if usesExternalTimeout && proc.terminationStatus == 124 {
        timedOut = true
    }

    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
    let stdoutData = finishPipeCapture(for: stdoutPipe, buffer: stdoutBuffer)
    let stderrData = finishPipeCapture(for: stderrPipe, buffer: stderrBuffer)

    return ScriptOutput(
        exitCode: timedOut ? -1 : proc.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        executionTimeMs: elapsed,
        timedOut: timedOut
    )
}

private func installPipeCapture(for pipe: Pipe, buffer: CapturedPipeBuffer) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        buffer.append(chunk)
    }
}

private func finishPipeCapture(for pipe: Pipe, buffer: CapturedPipeBuffer) -> Data {
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = nil
    buffer.append(handle.readDataToEndOfFile())
    return buffer.snapshot()
}

private func terminateScriptProcess(_ proc: Process, usesSeparateProcessGroup: Bool) {
    if usesSeparateProcessGroup {
        _ = kill(-proc.processIdentifier, SIGTERM)
    } else {
        proc.terminate()
    }

    Thread.sleep(forTimeInterval: 0.5)

    guard proc.isRunning else { return }
    let signalTarget = usesSeparateProcessGroup ? -proc.processIdentifier : proc.processIdentifier
    _ = kill(signalTarget, SIGKILL)
}

/// Phase 1: direct subprocess execution, no sandbox.
struct UnsandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        let proc = Process()
        let launch = configureUnsandboxedProcess(
            proc,
            script: script,
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds
        )

        return await executeScriptProcess(
            proc,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch script",
            usesSeparateProcessGroup: launch.usesSeparateProcessGroup,
            usesExternalTimeout: launch.usesExternalTimeout
        )
    }
}

private func configureUnsandboxedProcess(
    _ proc: Process,
    script: URL,
    workDir: URL,
    timeLimitSeconds: Int
) -> ProcessLaunchConfiguration {
    let invocation = scriptInvocation(for: script)
    proc.currentDirectoryURL = workDir

#if os(Linux)
    // Use coreutils timeout on Linux so the deadline is enforced from the
    // top-level utility rather than relying on Foundation.Process to reap a
    // subprocess tree it does not fully own.
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
    proc.arguments = [
        "--signal=TERM",
        "--kill-after=1s",
        "\(timeLimitSeconds)s",
        invocation.executableURL.path
    ] + invocation.arguments
    return ProcessLaunchConfiguration(
        usesSeparateProcessGroup: false,
        usesExternalTimeout: true
    )
#else
    proc.executableURL = invocation.executableURL
    proc.arguments = invocation.arguments
    return ProcessLaunchConfiguration(
        usesSeparateProcessGroup: false,
        usesExternalTimeout: false
    )
#endif
}
