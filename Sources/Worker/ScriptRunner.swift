// Worker/ScriptRunner.swift
//
// Protocol and Phase 1 (unsandboxed) implementation for running a single
// test script subprocess. Phase 4 will add SandboxedScriptRunner conforming
// to the same protocol without changing any callers.

import Core
import Foundation
import Synchronization

#if os(Linux)
import Glibc
#endif

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
///
/// `env` is merged into the process environment on top of the parent
/// process's environment. Empty dictionary = no overrides (parent env is
/// inherited verbatim).
protocol ScriptRunner: Sendable {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput
}

extension ScriptRunner {
    /// Convenience overload — call sites without per-run env-var needs can omit `env:`.
    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        await run(script: script, workDir: workDir, timeLimitSeconds: timeLimitSeconds, env: [:])
    }
}

struct ProcessLaunchConfiguration {
    let usesSeparateProcessGroup: Bool
    let usesExternalTimeout: Bool
}

#if os(Linux)
struct LinuxProcessLaunchConfiguration {
    let executablePath: String
    let arguments: [String]
    let env: [String: String]
}
#endif

private final class CapturedPipeBuffer: Sendable {
    private let storage = Mutex(Data())

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        storage.withLock { $0.append(chunk) }
    }

    func snapshot() -> Data {
        storage.withLock { $0 }
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

    // Mutex so the timeout Task and the main path can safely share this flag.
    let timedOut = Mutex(false)

    // Spawn a timeout Task instead of DispatchQueue.asyncAfter so the timeout
    // participates in Swift structured concurrency and supports cooperative
    // cancellation. The main path still calls waitUntilExit() — acceptable in
    // the worker daemon context where one thread per active job is expected.
    let timeoutTask: Task<Void, Never>?
    if usesExternalTimeout {
        timeoutTask = nil
    } else {
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeLimitSeconds) * 1_000_000_000)
            guard !Task.isCancelled, proc.isRunning else { return }
            timedOut.withLock { $0 = true }
            await terminateScriptProcess(proc, usesSeparateProcessGroup: usesSeparateProcessGroup)
        }
    }

    proc.waitUntilExit()
    timeoutTask?.cancel()

    if usesExternalTimeout && proc.terminationStatus == 124 {
        timedOut.withLock { $0 = true }
    }

    let didTimeOut = timedOut.withLock { $0 }
    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
    let stdoutData = finishPipeCapture(for: stdoutPipe, buffer: stdoutBuffer)
    let stderrData = finishPipeCapture(for: stderrPipe, buffer: stderrBuffer)

    return ScriptOutput(
        exitCode: didTimeOut ? -1 : proc.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        executionTimeMs: elapsed,
        timedOut: didTimeOut
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

private func terminateScriptProcess(_ proc: Process, usesSeparateProcessGroup: Bool) async {
    if usesSeparateProcessGroup {
        _ = kill(-proc.processIdentifier, SIGTERM)
    } else {
        proc.terminate()
    }

    try? await Task.sleep(nanoseconds: 500_000_000)

    guard proc.isRunning else { return }
    let signalTarget = usesSeparateProcessGroup ? -proc.processIdentifier : proc.processIdentifier
    _ = kill(signalTarget, SIGKILL)
}

/// Phase 1: direct subprocess execution, no sandbox.
struct UnsandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
        #if os(Linux)
        let launch = configureLinuxUnsandboxedProcess(
            script: script,
            workDir: workDir,
            env: env
        )

        return await executeLinuxScriptProcess(
            launch,
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch script"
        )
        #else
        let proc = Process()
        let launch = configureUnsandboxedProcess(
            proc,
            script: script,
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds,
            env: env
        )

        return await executeScriptProcess(
            proc,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch script",
            usesSeparateProcessGroup: launch.usesSeparateProcessGroup,
            usesExternalTimeout: launch.usesExternalTimeout
        )
        #endif
    }
}

private func configureUnsandboxedProcess(
    _ proc: Process,
    script: URL,
    workDir: URL,
    timeLimitSeconds: Int,
    env: [String: String]
) -> ProcessLaunchConfiguration {
    let invocation = scriptInvocation(for: script)
    proc.currentDirectoryURL = workDir

    proc.executableURL = invocation.executableURL
    proc.arguments = invocation.arguments
    proc.environment = mergedScriptEnvironment(overrides: env)
    return ProcessLaunchConfiguration(
        usesSeparateProcessGroup: false,
        usesExternalTimeout: false
    )
}

/// Merge `overrides` into the current process's environment. Overrides win
/// on key collision. Returns nil only when overrides is empty AND the caller
/// wants to inherit the parent env verbatim — but since we always copy via
/// `ProcessInfo.processInfo.environment`, we always return a non-nil dict.
func mergedScriptEnvironment(overrides: [String: String]) -> [String: String] {
    var base = ProcessInfo.processInfo.environment
    for (key, value) in overrides {
        base[key] = value
    }
    return base
}

#if os(Linux)
private func configureLinuxUnsandboxedProcess(
    script: URL,
    workDir: URL,
    env: [String: String]
) -> LinuxProcessLaunchConfiguration {
    let invocation = scriptInvocation(for: script)
    return LinuxProcessLaunchConfiguration(
        executablePath: invocation.executableURL.path,
        arguments: invocation.arguments,
        env: mergedScriptEnvironment(overrides: env)
    )
}

/// Holds the per-run pipe pair plus their shared buffers so the parent path
/// can install capture, hand the write ends to the child, then drain the
/// read ends after wait.
private struct LinuxScriptPipes {
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let stdoutBuffer: CapturedPipeBuffer
    let stderrBuffer: CapturedPipeBuffer
}

/// Result of `waitpid`-loop bookkeeping. `status` is the raw wait status; the
/// caller maps it to `ScriptOutput.exitCode` after taking the timeout flag
/// into account.
private struct LinuxWaitOutcome {
    let status: Int32
    let timedOut: Bool
}

func executeLinuxScriptProcess(
    _ launch: LinuxProcessLaunchConfiguration,
    workDir: URL,
    timeLimitSeconds: Int,
    launchErrorPrefix: String
) async -> ScriptOutput {
    let start = Date()
    let pipes = makeLinuxScriptPipes()

    let rawArguments = [launch.executablePath] + launch.arguments
    let executable = strdup(launch.executablePath)
    let argvStorage = rawArguments.map { strdup($0) }
    defer {
        if let executable { free(executable) }
        for pointer in argvStorage where pointer != nil {
            free(pointer)
        }
    }

    guard let executable else {
        return linuxLaunchFailure(
            prefix: launchErrorPrefix,
            detail: "out of memory",
            start: start
        )
    }

    let pid = fork()
    if pid == -1 {
        return linuxLaunchFailure(
            prefix: launchErrorPrefix,
            detail: String(cString: strerror(errno)),
            start: start
        )
    }

    if pid == 0 {
        linuxChildExec(
            pipes: pipes,
            workDir: workDir,
            envOverrides: launch.env,
            executable: executable,
            argvStorage: argvStorage
        )
        // execvp never returns on success; the child path _exit()s on error.
    }

    pipes.stdoutPipe.fileHandleForWriting.closeFile()
    pipes.stderrPipe.fileHandleForWriting.closeFile()

    let wait = linuxWaitForChild(pid: pid, timeLimitSeconds: timeLimitSeconds)

    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
    let stdoutData = finishPipeCapture(for: pipes.stdoutPipe, buffer: pipes.stdoutBuffer)
    let stderrData = finishPipeCapture(for: pipes.stderrPipe, buffer: pipes.stderrBuffer)
    let exitCode = wait.timedOut ? -1 : linuxExitCode(from: wait.status)

    return ScriptOutput(
        exitCode: exitCode,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        executionTimeMs: elapsed,
        timedOut: wait.timedOut
    )
}

private func makeLinuxScriptPipes() -> LinuxScriptPipes {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutBuffer = CapturedPipeBuffer()
    let stderrBuffer = CapturedPipeBuffer()
    installPipeCapture(for: stdoutPipe, buffer: stdoutBuffer)
    installPipeCapture(for: stderrPipe, buffer: stderrBuffer)
    return LinuxScriptPipes(
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        stdoutBuffer: stdoutBuffer,
        stderrBuffer: stderrBuffer
    )
}

private func linuxLaunchFailure(prefix: String, detail: String, start: Date) -> ScriptOutput {
    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
    return ScriptOutput(
        exitCode: 2,
        stdout: "",
        stderr: "\(prefix): \(detail)",
        executionTimeMs: elapsed,
        timedOut: false
    )
}

/// Runs in the forked child between `fork()` and `execvp`.  Sets up FDs,
/// applies env overrides, then execs. Always terminates the child via
/// `_exit(127)` on any failure path.  Never returns on success.
private func linuxChildExec(
    pipes: LinuxScriptPipes,
    workDir: URL,
    envOverrides: [String: String],
    executable: UnsafeMutablePointer<CChar>,
    argvStorage: [UnsafeMutablePointer<CChar>?]
) {
    let stdoutRead = pipes.stdoutPipe.fileHandleForReading.fileDescriptor
    let stdoutWrite = pipes.stdoutPipe.fileHandleForWriting.fileDescriptor
    let stderrRead = pipes.stderrPipe.fileHandleForReading.fileDescriptor
    let stderrWrite = pipes.stderrPipe.fileHandleForWriting.fileDescriptor

    _ = Glibc.close(stdoutRead)
    _ = Glibc.close(stderrRead)

    if dup2(stdoutWrite, STDOUT_FILENO) == -1 || dup2(stderrWrite, STDERR_FILENO) == -1 {
        _exit(127)
    }

    _ = Glibc.close(stdoutWrite)
    _ = Glibc.close(stderrWrite)

    if chdir(workDir.path) == -1 {
        _exit(127)
    }

    if setsid() == -1 {
        _exit(127)
    }

    // Apply env overrides to the child's `environ` before exec.  setenv()
    // with overwrite=1 mutates the child's copy of the parent env; execvp
    // then inherits it.
    for (key, value) in envOverrides {
        _ = setenv(key, value, 1)
    }

    var argv = argvStorage + [nil]
    execvp(executable, &argv)
    _exit(127)
}

/// Polls `waitpid` until the child exits or the deadline is hit. On
/// timeout, sends SIGTERM to the process group, sleeps briefly, then SIGKILL
/// and reaps.  Returns the final wait status plus a timeout flag.
private func linuxWaitForChild(pid: pid_t, timeLimitSeconds: Int) -> LinuxWaitOutcome {
    var timedOut = false
    var status: Int32 = 0
    let deadline = Date().addingTimeInterval(TimeInterval(timeLimitSeconds))

    while true {
        let waitResult = waitpid(pid, &status, WNOHANG)
        if waitResult == pid {
            break
        }

        if waitResult == -1 {
            status = 127
            break
        }

        if Date() >= deadline {
            timedOut = true
            _ = kill(-pid, SIGTERM)
            usleep(250_000)
            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = kill(-pid, SIGKILL)
            }
            _ = waitpid(pid, &status, 0)
            break
        }

        usleep(50_000)
    }

    return LinuxWaitOutcome(status: status, timedOut: timedOut)
}

private func linuxExitCode(from status: Int32) -> Int32 {
    if linuxDidExit(status) {
        return Int32((status >> 8) & 0xff)
    }
    if linuxWasSignaled(status) {
        return -Int32(status & 0x7f)
    }
    return status
}

private func linuxDidExit(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}

private func linuxWasSignaled(_ status: Int32) -> Bool {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f
}
#endif
