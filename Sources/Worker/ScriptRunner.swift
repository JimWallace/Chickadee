// Worker/ScriptRunner.swift
//
// Protocol and unsandboxed implementation for running a single test script
// subprocess. `SandboxedScriptRunner` conforms to the same protocol for the
// `--sandbox` path without changing any callers.

import Core
import Foundation
import Synchronization

#if os(Linux)
import Glibc
#endif

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
///
/// `env` is merged on top of an allowlisted subset of the worker's
/// environment (see `mergedScriptEnvironment`); the daemon's secrets are not
/// inherited. Empty dictionary = the allowlisted base only.
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
    /// Per-stream capture cap. A student script printing in a tight loop for
    /// its whole time limit could otherwise grow this buffer without bound,
    /// OOM the worker (taking down the other concurrent jobs), and ride the
    /// blob into `longResult` → JSON → DB (June 2026 audit, P2.1). 1 MB keeps
    /// every realistic traceback intact.
    static let maxCapturedBytes = 1_048_576

    private struct State {
        var data = Data()
        var truncated = false
    }

    private let storage = Mutex(State())

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        storage.withLock { state in
            guard !state.truncated else { return }
            let remaining = Self.maxCapturedBytes - state.data.count
            if chunk.count <= remaining {
                state.data.append(chunk)
            } else {
                if remaining > 0 { state.data.append(chunk.prefix(remaining)) }
                state.truncated = true
                state.data.append(Data("\n... output truncated (limit 1 MB) ...\n".utf8))
            }
        }
    }

    func snapshot() -> Data {
        storage.withLock { $0.data }
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
    setCloseOnExec(stdoutPipe)
    setCloseOnExec(stderrPipe)
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
    // cancellation.
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

    // Suspend until exit instead of blocking on waitUntilExit(): the Swift
    // cooperative pool has ~one thread per core and never grows, so a blocking
    // wait per running script could pin every pool thread — starving the
    // heartbeat tasks and (worst case) the timeout Task that is supposed to
    // kill the hung script (June 2026 audit, P1.5).
    //
    // The handler is installed after run(), so guard the already-exited race:
    // if the process exited before the handler was set the handler never
    // fires, and if it exits in between both paths may fire — `resumed` keeps
    // the continuation single-shot either way.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumed = Mutex(false)
        let resumeOnce: @Sendable () -> Void = {
            let alreadyResumed = resumed.withLock { wasResumed in
                let previous = wasResumed
                wasResumed = true
                return previous
            }
            if !alreadyResumed { continuation.resume() }
        }
        proc.terminationHandler = { _ in resumeOnce() }
        if !proc.isRunning { resumeOnce() }
    }
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

/// Foundation's `Pipe` does not set `FD_CLOEXEC` (verified on Swift 6.3 /
/// glibc 2.39 and Darwin). Without it, any subprocess spawned concurrently
/// with this run — another job's fork, a `Process` launch elsewhere in the
/// daemon or test process — inherits duplicates of these descriptors across
/// its exec, and the read side then never sees EOF until that unrelated
/// process exits (issue #1139's cross-test stall). The intended child still
/// receives its ends: `dup2`/spawn file actions clear the flag on the
/// duplicate they install.
///
/// Internal (not private): every worker-side subprocess pipe should go
/// through this — a single non-CLOEXEC pipe elsewhere re-opens the
/// EOF-starvation window for everyone (issue #1233).
func setCloseOnExec(_ pipe: Pipe) {
    for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1 else { continue }
        _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }
}

private func finishPipeCapture(for pipe: Pipe, buffer: CapturedPipeBuffer) -> Data {
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = nil
    drainRemainingPipeData(fromDescriptor: handle.fileDescriptor, into: buffer)
    return buffer.snapshot()
}

/// Final drain after the child has been reaped: everything it wrote is
/// already in the kernel pipe buffer, so a zero-byte read means EOF and the
/// happy path completes on the first iteration. Bounded by a short deadline
/// because a leaked duplicate of the write end in an unrelated process keeps
/// EOF from ever arriving — the previous blocking `readDataToEndOfFile()`
/// turned exactly that into an unbounded stall on a cooperative-pool thread
/// (issue #1139); now stragglers get a grace period and we keep what we have.
private func drainRemainingPipeData(fromDescriptor descriptor: Int32, into buffer: CapturedPipeBuffer) {
    let deadline = Date().addingTimeInterval(2)
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let readyCount = poll(&pollDescriptor, 1, 100)
        if readyCount == -1 {
            if errno == EINTR { continue }
            return
        }
        if readyCount > 0 {
            let bytesRead = read(descriptor, &chunk, chunk.count)
            if bytesRead > 0 {
                buffer.append(Data(chunk[0..<bytesRead]))
                continue
            }
            if bytesRead == -1 && errno == EINTR { continue }
            return  // 0 = EOF (every write end closed); -1 = unrecoverable.
        }
        if Date() >= deadline { return }
    }
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

/// Environment keys a test script is allowed to inherit from the worker
/// process. Everything else — notably `RUNNER_SHARED_SECRET`, DB URLs, and
/// any other worker credential present in the daemon's environment — is
/// withheld so a student submission cannot read it back out via stdout/stderr
/// and forge worker API requests. Per-job values (`CHICKADEE_*`, seed inputs)
/// arrive through `overrides`, which always win.
private let scriptEnvironmentAllowlistKeys: Set<String> = [
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "LANG",
    "TERM", "PWD",
]

/// Key prefixes whose every member is safe to inherit (locale + the per-job
/// Chickadee namespace).
private let scriptEnvironmentAllowlistPrefixes: [String] = ["LC_", "CHICKADEE_"]

private func isAllowlistedScriptEnvironmentKey(_ key: String) -> Bool {
    if scriptEnvironmentAllowlistKeys.contains(key) { return true }
    return scriptEnvironmentAllowlistPrefixes.contains { key.hasPrefix($0) }
}

/// Build the environment for a test-script subprocess: an allowlisted subset
/// of the worker's environment, plus `overrides` (which win on collision).
///
/// The worker daemon runs with secrets in its environment (`RUNNER_SHARED_SECRET`,
/// database URLs, OIDC client secrets); inheriting the full environment would
/// hand those to arbitrary student code. We therefore start from an allowlist
/// rather than `ProcessInfo.processInfo.environment` wholesale.
func mergedScriptEnvironment(overrides: [String: String]) -> [String: String] {
    var base: [String: String] = [:]
    for (key, value) in ProcessInfo.processInfo.environment
    where isAllowlistedScriptEnvironmentKey(key) {
        base[key] = value
    }
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
private struct LinuxWaitOutcome: Sendable {
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

    // Materialize every buffer the child touches BEFORE fork(). fork() in a
    // multithreaded process snapshots glibc's locks (malloc arenas, the
    // environ lock) in whatever state other threads held them, with no thread
    // left in the child to ever release them — so between fork() and execve()
    // only async-signal-safe calls are allowed. An earlier revision called
    // setenv() and bridged Swift Strings in the child and deadlocked under
    // parallel-test load: the 60 s stalls and 20-minute job wedges of
    // issue #1139.
    let rawArguments = [launch.executablePath] + launch.arguments
    let environmentEntries = launch.env.map { "\($0.key)=\($0.value)" }
    let executableOrNil = strdup(launch.executablePath)
    let workDirPathOrNil = strdup(workDir.path)
    guard let executable = executableOrNil, let workDirPath = workDirPathOrNil else {
        if let executableOrNil { free(executableOrNil) }
        if let workDirPathOrNil { free(workDirPathOrNil) }
        return linuxLaunchFailure(
            prefix: launchErrorPrefix,
            detail: "out of memory",
            start: start
        )
    }
    let argv = CStringVector(rawArguments)
    let envp = CStringVector(environmentEntries)
    defer {
        free(executable)
        free(workDirPath)
        argv.deallocate()
        envp.deallocate()
    }

    let pipes = makeLinuxScriptPipes()
    // Resolve the raw descriptors up front: the child must not call into
    // Foundation (FileHandle property accesses included) after fork().
    let childDescriptors = LinuxChildDescriptors(
        stdoutRead: pipes.stdoutPipe.fileHandleForReading.fileDescriptor,
        stdoutWrite: pipes.stdoutPipe.fileHandleForWriting.fileDescriptor,
        stderrRead: pipes.stderrPipe.fileHandleForReading.fileDescriptor,
        stderrWrite: pipes.stderrPipe.fileHandleForWriting.fileDescriptor
    )

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
            descriptors: childDescriptors,
            workDirPath: workDirPath,
            executable: executable,
            argv: argv.pointer,
            envp: envp.pointer
        )
        // execve never returns on success; the child path _exit()s on error.
    }

    pipes.stdoutPipe.fileHandleForWriting.closeFile()
    pipes.stderrPipe.fileHandleForWriting.closeFile()

    // Run the waitpid poll loop on a dedicated OS thread and suspend here:
    // the loop blocks (usleep between WNOHANG polls) for up to the full time
    // limit, and the cooperative pool must not lose a thread per running
    // script (June 2026 audit, P1.5). One short-lived thread per active job,
    // bounded by --max-jobs.
    let wait = await withCheckedContinuation { (continuation: CheckedContinuation<LinuxWaitOutcome, Never>) in
        Thread.detachNewThread {
            continuation.resume(returning: linuxWaitForChild(pid: pid, timeLimitSeconds: timeLimitSeconds))
        }
    }

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
    setCloseOnExec(stdoutPipe)
    setCloseOnExec(stderrPipe)
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

/// A NULL-terminated C string vector (the argv/envp shape) materialized in
/// the parent before `fork()` so the forked child never allocates.
private struct CStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[count] = nil
    }

    func deallocate() {
        for index in 0..<count {
            if let entry = pointer[index] { free(entry) }
        }
        pointer.deallocate()
    }
}

/// The four pipe descriptors, resolved from Foundation handles pre-fork so
/// the child works with plain integers only.
private struct LinuxChildDescriptors {
    let stdoutRead: Int32
    let stdoutWrite: Int32
    let stderrRead: Int32
    let stderrWrite: Int32
}

/// Runs in the forked child between `fork()` and `execve`.
///
/// The parent is heavily multithreaded (Swift concurrency pool, Dispatch
/// pipe readers, parallel test scheduler), so this function may only use
/// async-signal-safe calls: close/dup2/setsid/sigprocmask/chdir/execve/_exit.
/// No Swift allocation, no String bridging, no setenv — any of those can
/// block on a glibc lock that fork() captured mid-acquire, deadlocking the
/// child forever (issue #1139). Every input is a raw C buffer materialized
/// by the caller before fork(). Always terminates the child via `_exit(127)`
/// on any failure path.  Never returns on success.
private func linuxChildExec(
    descriptors: LinuxChildDescriptors,
    workDirPath: UnsafePointer<CChar>,
    executable: UnsafePointer<CChar>,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) {
    // New session (and process group) first, so the parent's timeout
    // group-kill can reach this child even if a later step here wedges.
    if setsid() == -1 {
        _exit(127)
    }

    _ = Glibc.close(descriptors.stdoutRead)
    _ = Glibc.close(descriptors.stderrRead)

    if dup2(descriptors.stdoutWrite, STDOUT_FILENO) == -1
        || dup2(descriptors.stderrWrite, STDERR_FILENO) == -1
    {
        _exit(127)
    }

    _ = Glibc.close(descriptors.stdoutWrite)
    _ = Glibc.close(descriptors.stderrWrite)

    if chdir(workDirPath) == -1 {
        _exit(127)
    }

    // The forking thread's signal mask survives execve; unblock everything so
    // an inherited blocked SIGTERM can't neuter the timeout kill's first,
    // graceful stage.
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    _ = sigprocmask(SIG_UNBLOCK, &allSignals, nil)

    _ = execve(executable, argv, envp)
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
            // The child setsid()s first thing, so the group kill normally
            // lands; the direct-pid kill covers the fork()→setsid() window.
            _ = kill(-pid, SIGTERM)
            _ = kill(pid, SIGTERM)
            usleep(250_000)
            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
            // Bounded reap — never a blocking waitpid() here. A child that a
            // missed kill left running once pinned this thread (and with it
            // the whole test process) until the CI job-level timeout: the
            // 20-minute wedge shape of issue #1139. SIGKILLed processes reap
            // within milliseconds; five seconds of grace is generous.
            var reapAttempts = 0
            while waitpid(pid, &status, WNOHANG) == 0, reapAttempts < 100 {
                reapAttempts += 1
                usleep(50_000)
            }
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
