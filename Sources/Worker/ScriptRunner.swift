// Worker/ScriptRunner.swift
//
// Protocol and Phase 1 (unsandboxed) implementation for running a single
// test script subprocess. Phase 4 will add SandboxedScriptRunner conforming
// to the same protocol without changing any callers.

import Foundation
#if os(Linux)
import Glibc
#endif

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
protocol ScriptRunner {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput
}

struct ProcessLaunchConfiguration {
    let usesSeparateProcessGroup: Bool
    let usesExternalTimeout: Bool
}

#if os(Linux)
struct LinuxProcessLaunchConfiguration {
    let executablePath: String
    let arguments: [String]
}
#endif

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
#if os(Linux)
        let launch = configureLinuxUnsandboxedProcess(
            script: script,
            workDir: workDir
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
            timeLimitSeconds: timeLimitSeconds
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
    timeLimitSeconds: Int
) -> ProcessLaunchConfiguration {
    let invocation = scriptInvocation(for: script)
    proc.currentDirectoryURL = workDir

    proc.executableURL = invocation.executableURL
    proc.arguments = invocation.arguments
    return ProcessLaunchConfiguration(
        usesSeparateProcessGroup: false,
        usesExternalTimeout: false
    )
}

#if os(Linux)
private func configureLinuxUnsandboxedProcess(
    script: URL,
    workDir: URL
) -> LinuxProcessLaunchConfiguration {
    let invocation = scriptInvocation(for: script)
    return LinuxProcessLaunchConfiguration(
        executablePath: invocation.executableURL.path,
        arguments: invocation.arguments
    )
}

private func executeLinuxScriptProcess(
    _ launch: LinuxProcessLaunchConfiguration,
    workDir: URL,
    timeLimitSeconds: Int,
    launchErrorPrefix: String
) async -> ScriptOutput {
    let start = Date()

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutBuffer = CapturedPipeBuffer()
    let stderrBuffer = CapturedPipeBuffer()

    installPipeCapture(for: stdoutPipe, buffer: stdoutBuffer)
    installPipeCapture(for: stderrPipe, buffer: stderrBuffer)

    let executable = strdup(launch.executablePath)
    let argvStorage = ([launch.executablePath] + launch.arguments).map(strdup)
    defer {
        if let executable {
            free(executable)
        }
        for pointer in argvStorage {
            if let pointer {
                free(pointer)
            }
        }
    }

    guard let executable else {
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return ScriptOutput(
            exitCode: 2,
            stdout: "",
            stderr: "\(launchErrorPrefix): out of memory",
            executionTimeMs: elapsed,
            timedOut: false
        )
    }

    let pid = fork()
    if pid == -1 {
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return ScriptOutput(
            exitCode: 2,
            stdout: "",
            stderr: "\(launchErrorPrefix): \(String(cString: strerror(errno)))",
            executionTimeMs: elapsed,
            timedOut: false
        )
    }

    if pid == 0 {
        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor

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

        var argv = argvStorage + [nil]
        execvp(executable, &argv)
        _exit(127)
    }

    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

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

    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
    let stdoutData = finishPipeCapture(for: stdoutPipe, buffer: stdoutBuffer)
    let stderrData = finishPipeCapture(for: stderrPipe, buffer: stderrBuffer)
    let exitCode = timedOut ? -1 : linuxExitCode(from: status)

    return ScriptOutput(
        exitCode: exitCode,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        executionTimeMs: elapsed,
        timedOut: timedOut
    )
}

private func linuxExitCode(from status: Int32) -> Int32 {
    if WIFEXITED(status) {
        return WEXITSTATUS(status)
    }
    if WIFSIGNALED(status) {
        return -Int32(WTERMSIG(status))
    }
    return status
}
#endif
