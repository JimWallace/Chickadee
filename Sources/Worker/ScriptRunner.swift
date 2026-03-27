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
    usesSeparateProcessGroup: Bool
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
    let timeoutItem = DispatchWorkItem {
        guard proc.isRunning else { return }
        timedOut = true
        terminateScriptProcess(proc, usesSeparateProcessGroup: usesSeparateProcessGroup)
    }
    DispatchQueue.global().asyncAfter(
        deadline: .now() + .seconds(timeLimitSeconds),
        execute: timeoutItem
    )

    proc.waitUntilExit()
    timeoutItem.cancel()

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
        let usesSeparateProcessGroup = configureUnsandboxedProcess(proc, script: script, workDir: workDir)

        return await executeScriptProcess(
            proc,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch script",
            usesSeparateProcessGroup: usesSeparateProcessGroup
        )
    }
}

private func configureUnsandboxedProcess(_ proc: Process, script: URL, workDir: URL) -> Bool {
    let invocation = scriptInvocation(for: script)
    proc.currentDirectoryURL = workDir

#if os(Linux)
    // Run each script as its own session leader so timeout handling can reap
    // the entire subprocess tree, not just the top-level shell.
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["setsid", invocation.executableURL.path] + invocation.arguments
    return true
#else
    proc.executableURL = invocation.executableURL
    proc.arguments = invocation.arguments
    return false
#endif
}
