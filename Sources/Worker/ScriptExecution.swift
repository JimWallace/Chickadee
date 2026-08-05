// Worker/ScriptExecution.swift
//
// The worker's single subprocess-launch path. Every script the runner
// executes — sandboxed, unsandboxed, and the optional `make` build step —
// goes through `executeScriptLaunch`, on every platform.
//
// This used to be two implementations. macOS drove Foundation's `Process`;
// Linux drove a hand-written fork()/execve()/waitpid() sequence, because
// forking from the heavily multithreaded daemon (Swift concurrency pool,
// Dispatch pipe readers, parallel test scheduler) snapshots glibc's malloc
// and environ locks in whatever state other threads held them, with no thread
// left in the child to release them — the 60 s stalls and 20-minute job
// wedges of issue #1139. swift-subprocess spawns without that hazard and is
// CI-tested on the distributions the runner ships on, so the two paths
// collapse back into one and the async-signal-safety burden goes away.
//
// What this file still owns, because Subprocess deliberately doesn't:
//
//   • Bounded output capture. Subprocess's `.string(limit:)` *throws* once a
//     child exceeds the limit; a student script printing in a tight loop must
//     still grade, with the first megabyte kept and a truncation marker
//     appended. So output is streamed (`.sequence`) into `CapturedPipeBuffer`.
//
//   • The time limit. The deadline is ours to enforce and ours to report:
//     `ScriptOutput.timedOut` is an explicit flag, not something inferred
//     from a termination signal, and `interpretScriptOutput` keys the
//     `timeout` status off it (pinned by Tests/Fixtures/output-contract.json).

import Core
import Foundation
import RunnerCore
import Subprocess
import Synchronization
import SystemPackage

/// A fully-resolved subprocess launch: the executable to exec, its argument
/// vector, and the exact environment the child receives. Building one is the
/// only platform-specific part of running a script — the sandbox wrappers
/// differ from the unsandboxed path in nothing but the executable and args.
struct ScriptLaunch: Sendable {
    let executablePath: String
    let arguments: [String]
    let env: [String: String]
}

/// Runs `launch` in `workDir` under `timeLimitSeconds`, capturing stdout and
/// stderr, and reports the result in the shared `ScriptOutput` shape.
///
/// Never throws: a launch failure (executable missing, `posix_spawn` refused,
/// an environment entry Subprocess rejects) becomes exit code 2 — the script
/// contract's "error" — with `launchErrorPrefix` leading the stderr text.
/// Exit code `-1` therefore means exactly one thing: the script hit the time
/// limit and was killed.
func executeScriptLaunch(
    _ launch: ScriptLaunch,
    workDir: URL,
    timeLimitSeconds: Int,
    launchErrorPrefix: String
) async -> ScriptOutput {
    let start = Date()
    let stdoutBuffer = CapturedPipeBuffer()
    let stderrBuffer = CapturedPipeBuffer()

    do {
        let result = try await Subprocess.run(
            .path(FilePath(launch.executablePath)),
            arguments: Arguments(launch.arguments),
            environment: .custom(subprocessEnvironment(launch.env)),
            workingDirectory: FilePath(workDir.path),
            platformOptions: scriptPlatformOptions(),
            input: .none,
            output: .sequence,
            error: .sequence
        ) { execution in
            await runScriptBody(
                execution,
                timeLimitSeconds: timeLimitSeconds,
                stdoutBuffer: stdoutBuffer,
                stderrBuffer: stderrBuffer
            )
        }

        let didTimeOut = result.closureResult
        return ScriptOutput(
            exitCode: didTimeOut ? -1 : exitCode(from: result.terminationStatus),
            stdout: stdoutBuffer.text(),
            stderr: stderrBuffer.text(),
            executionTimeMs: elapsedMs(since: start),
            timedOut: didTimeOut
        )
    } catch {
        return ScriptOutput(
            exitCode: 2,
            stdout: "",
            stderr: "\(launchErrorPrefix): \(error)",
            executionTimeMs: elapsedMs(since: start),
            timedOut: false
        )
    }
}

// MARK: - Launch configuration

/// The signal ladder used to stop a script that overran its time limit, and
/// to stop one whose enclosing task was cancelled.
///
/// SIGTERM first so a script that installs a handler can report something,
/// then the implicit SIGKILL that `teardown(using:)` always appends. Both go
/// to the whole process group — a script that backgrounds a child must not
/// leave it running — which is safe to do only because `createSession` puts
/// the child in a session of its own; without that, "the process group"
/// would include the worker itself.
private let scriptTeardownSequence: [TeardownStep] = [
    .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .milliseconds(500))
]

private func scriptPlatformOptions() -> PlatformOptions {
    var options = PlatformOptions()
    // setsid(2) in the child: its own session and process group, so the
    // group-wide kill above reaches every process the script spawned and
    // nothing else. Previously this was Linux-only; the macOS path sent
    // SIGTERM to the direct child alone and leaked backgrounded children.
    options.createSession = true
    // Cancelling the enclosing task — a cancelled job, a shutting-down
    // daemon — now tears the script down too. The old Linux path polled
    // waitpid on a detached thread and never observed cancellation at all,
    // so a cancelled job left its script running to completion.
    options.teardownSequence = scriptTeardownSequence
    return options
}

/// Bridges Chickadee's `[String: String]` environment to Subprocess's keyed
/// form. `Environment.Key` has no public non-failable initializer; the
/// failable one never actually fails, so a `nil` key is unreachable rather
/// than a silent drop worth reporting.
private func subprocessEnvironment(_ env: [String: String]) -> [Environment.Key: String] {
    var custom: [Environment.Key: String] = [:]
    for (key, value) in env {
        guard let environmentKey = Environment.Key(rawValue: key) else { continue }
        custom[environmentKey] = value
    }
    return custom
}

// MARK: - Running body

/// What ended the run. The body waits for `.streamsClosed` either way: when
/// the watchdog fires it kills the child, which closes the streams, so the
/// drains always terminate.
private enum ScriptRunPhase: Sendable {
    /// Both output streams reached EOF — the child and everything holding a
    /// write end are gone.
    case streamsClosed
    /// The time limit elapsed and the teardown ladder has been run.
    case deadlineElapsed
    /// The deadline sleep was cancelled because the streams closed first.
    case watchdogStoodDown
}

/// Drains both output streams to EOF while a watchdog enforces the time
/// limit, and reports whether the watchdog was the one that ended the run.
private func runScriptBody<Input: InputProtocol>(
    _ execution: Execution<Input, SequenceOutput, SequenceOutput>,
    timeLimitSeconds: Int,
    stdoutBuffer: CapturedPipeBuffer,
    stderrBuffer: CapturedPipeBuffer
) async -> Bool {
    let timedOut = TimeoutFlag()

    await withTaskGroup(of: ScriptRunPhase.self) { group in
        group.addTask {
            await withTaskGroup(of: Void.self) { drains in
                drains.addTask { await drain(execution.standardOutput, into: stdoutBuffer) }
                drains.addTask { await drain(execution.standardError, into: stderrBuffer) }
            }
            return .streamsClosed
        }

        group.addTask {
            do {
                try await Task.sleep(for: .seconds(timeLimitSeconds))
            } catch {
                return .watchdogStoodDown
            }
            timedOut.mark()
            await execution.teardown(using: scriptTeardownSequence)
            return .deadlineElapsed
        }

        // The watchdog may report first (it kills, then the drains finish) or
        // never (the script exited on its own). Either way the body returns
        // only once the streams are closed, so no output is dropped.
        while let phase = await group.next() {
            if phase == .streamsClosed {
                group.cancelAll()
                break
            }
        }
    }

    return timedOut.isSet
}

/// One-way flag the watchdog raises before tearing the child down. A class
/// rather than a bare `Mutex` because the task-group children that touch it
/// take it as a `sending` capture, which a noncopyable value can't satisfy.
private final class TimeoutFlag: Sendable {
    private let storage = Mutex(false)

    func mark() { storage.withLock { $0 = true } }

    var isSet: Bool { storage.withLock { $0 } }
}

private func drain(_ sequence: SubprocessOutputSequence, into buffer: CapturedPipeBuffer) async {
    do {
        for try await chunk in sequence {
            let bytes = chunk.withUnsafeBytes { Data($0) }
            buffer.append(bytes)
        }
    } catch {
        // A read error mid-stream loses the tail, not the run: whatever
        // arrived is still the child's output and still worth showing.
    }
}

// MARK: - Result mapping

/// Maps a termination status to the exit code the script contract speaks:
/// the exit status for a normal exit, and the negated signal number for a
/// signalled death (so a SIGKILLed script reports `-9`, which
/// `interpretScriptOutput` reads as `error` unless `timedOut` overrides it).
private func exitCode(from status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code): return code
    case .signaled(let signal): return -signal
    }
}

private func elapsedMs(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

// MARK: - Bounded capture

/// Accumulates one output stream under a hard byte cap.
///
/// A student script printing in a tight loop for its whole time limit could
/// otherwise grow this buffer without bound, OOM the worker (taking down the
/// other concurrent jobs), and ride the blob into `longResult` → JSON → DB
/// (June 2026 audit, P2.1). 1 MB keeps every realistic traceback intact.
final class CapturedPipeBuffer: Sendable {
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

    func text() -> String {
        String(data: storage.withLock { $0.data }, encoding: .utf8) ?? ""
    }
}
