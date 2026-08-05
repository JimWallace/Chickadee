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
//   • The capture pipes. We create them, set FD_CLOEXEC, and hand Subprocess
//     the write ends via `.fileDescriptor(_:closeAfterSpawningProcess:)`.
//     Subprocess's own pipes come from swift-system's `FileDescriptor.pipe()`,
//     which is bare `pipe(2)` with no `O_CLOEXEC` — so a process spawned
//     concurrently with the child inherits a duplicate of the write end and
//     the read side never sees EOF (issues #1139/#1233). That is fatal on the
//     `.sequence` output path: its `AsyncSequence` has no cancellation handler
//     anywhere in the library, so a drain parked on an EOF that will never
//     arrive cannot be cancelled, the body never returns, `run` never returns,
//     and enough of those starve the cooperative pool and wedge the process.
//     Owning the pipes restores both guards at once: CLOEXEC on creation, and
//     a deadline-bounded final drain.
//
//   • Bounded output capture. Subprocess's `.string(limit:)` *throws* once a
//     child exceeds the limit; a student script printing in a tight loop must
//     still grade, with the first megabyte kept and a truncation marker
//     appended. Output accumulates into `CapturedPipeBuffer` instead, drained
//     concurrently so a child writing more than one pipe buffer never blocks
//     on a full pipe.
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
    let capture = ScriptCapture()

    do {
        let result = try await Subprocess.run(
            .path(FilePath(launch.executablePath)),
            arguments: Arguments(launch.arguments),
            environment: .custom(subprocessEnvironment(launch.env)),
            workingDirectory: FilePath(workDir.path),
            platformOptions: scriptPlatformOptions(),
            input: .none,
            output: capture.standardOutputTarget,
            error: capture.standardErrorTarget
        ) { execution in
            await runScriptWatchdog(
                execution, capture: capture, timeLimitSeconds: timeLimitSeconds)
        }

        let didTimeOut = result.closureResult
        let captured = capture.finish()
        return ScriptOutput(
            exitCode: didTimeOut ? -1 : exitCode(from: result.terminationStatus),
            stdout: captured.stdout,
            stderr: captured.stderr,
            executionTimeMs: elapsedMs(since: start),
            timedOut: didTimeOut
        )
    } catch {
        capture.discard()
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

/// The body of the run: nothing but the time-limit watchdog. Output capture
/// happens on the pipes `ScriptCapture` owns, not here — see the file comment
/// for why draining Subprocess's own `.sequence` streams is unsafe under
/// concurrent spawns.
///
/// Returns whether the watchdog was the one that ended the run.
///
/// EOF on both capture streams is the exit signal — what `.sequence` would
/// have provided, except that these are pipes we made close-on-exec and drain
/// on a deadline, so a leaked write-end duplicate degrades to a slow run
/// rather than a permanent hang.
private func runScriptWatchdog<Input: InputProtocol, Output: OutputProtocol, Error: ErrorOutputProtocol>(
    _ execution: Execution<Input, Output, Error>,
    capture: ScriptCapture,
    timeLimitSeconds: Int
) async -> Bool {
    // The verdict rides a flag rather than which task finishes first:
    // `teardown` waits for the process to die, so by the time it returns the
    // streams have closed too and either task may report first. Racing them
    // for the answer reports a timed-out script as a normal exit.
    let timedOut = TimeoutFlag()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            // Bounded a little past the time limit: by then the watchdog has
            // killed the child, so EOF is due. The bound bites only when a
            // leaked descriptor is holding a stream open.
            await capture.awaitStreamsClosed(withinSeconds: timeLimitSeconds + 5)
        }

        group.addTask {
            do {
                try await Task.sleep(for: .seconds(timeLimitSeconds))
            } catch {
                return  // cancelled: the script finished on its own
            }
            // Don't claim a timeout for a script that exited in the instant
            // the limit expired.
            guard !capture.streamsClosed else { return }
            timedOut.mark()
            await execution.teardown(using: scriptTeardownSequence)
        }

        await group.next()
        group.cancelAll()
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

// MARK: - Capture pipes

/// The two capture pipes for one script run: created here so they can be made
/// close-on-exec, drained continuously so a chatty child never blocks on a
/// full pipe, and torn down on a deadline so a leaked write-end duplicate can
/// postpone EOF but never hang the worker.
///
/// Each stream is drained by a dedicated short-lived thread rather than on the
/// cooperative pool. The pool has roughly one thread per core and never grows,
/// so parking two of its threads per running script would starve the very
/// tasks meant to enforce the time limit (June 2026 audit, P1.5). Thread count
/// is bounded by `--max-jobs`.
final class ScriptCapture: Sendable {
    private struct Stream {
        let readEnd: Int32
        let writeEnd: Int32
        let buffer = CapturedPipeBuffer()
    }

    /// Grace given to the final drain after the child should be gone. Whatever
    /// it wrote is already in the kernel pipe buffer, so the happy path
    /// completes immediately; the deadline only bounds the leaked-descriptor
    /// case.
    private static let drainGraceSeconds: TimeInterval = 2

    /// Handshake between the drain threads (and the deadline) on one side and
    /// the awaiting task on the other.
    ///
    /// A plain "resume the stored continuation" flag is not enough: the
    /// streams can reach EOF before the awaiting task has stored its
    /// continuation, and a signal that arrives first must be remembered rather
    /// than dropped. Losing it deadlocks the run — which is exactly what a
    /// first cut of this type did.
    private enum Completion {
        /// No signal yet, nobody waiting.
        case idle
        /// Signalled before anyone waited; the next waiter resumes at once.
        case signalled
        /// A waiter is parked on this continuation.
        case waiting(CheckedContinuation<Void, Never>)
        /// The waiter has been resumed; further signals are no-ops.
        case done
    }

    private let standardOutput: Stream
    private let standardError: Stream
    private let completion = Mutex(Completion.idle)
    private let openStreams = Mutex(2)

    init() {
        standardOutput = Self.makeStream()
        standardError = Self.makeStream()
    }

    /// A pipe whose descriptors are close-on-exec from the moment they exist.
    ///
    /// Without this, a subprocess spawned concurrently with our child
    /// inherits a duplicate of the write end across its exec, and the read
    /// side never sees EOF until that unrelated process exits (#1139/#1233).
    /// Subprocess's own pipes do not set the flag, which is why we supply
    /// ours rather than using `.sequence`.
    private static func makeStream() -> Stream {
        var descriptors: (Int32, Int32) = (-1, -1)
        _ = withUnsafeMutablePointer(to: &descriptors) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        for descriptor in [descriptors.0, descriptors.1] {
            let flags = fcntl(descriptor, F_GETFD)
            if flags != -1 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
        }
        return Stream(readEnd: descriptors.0, writeEnd: descriptors.1)
    }

    /// The write ends, handed to Subprocess. `closeAfterSpawningProcess` makes
    /// it close the parent's copy once the child holds its own — required for
    /// EOF, and the reason this type never closes a write end itself.
    var standardOutputTarget: FileDescriptorOutput {
        .fileDescriptor(FileDescriptor(rawValue: standardOutput.writeEnd), closeAfterSpawningProcess: true)
    }

    var standardErrorTarget: FileDescriptorOutput {
        .fileDescriptor(FileDescriptor(rawValue: standardError.writeEnd), closeAfterSpawningProcess: true)
    }

    /// True once both streams have reached EOF, i.e. the child and everything
    /// holding a write end are gone.
    var streamsClosed: Bool { openStreams.withLock { $0 } == 0 }

    /// Starts draining both streams, then suspends until both reach EOF or
    /// `withinSeconds` elapses — whichever comes first. Always resumes.
    func awaitStreamsClosed(withinSeconds: Int) async {
        for stream in [standardOutput, standardError] {
            Thread.detachNewThread { [self] in
                drainToEOF(stream)
                noteStreamClosed()
            }
        }

        let deadline = Task {
            try? await Task.sleep(for: .seconds(withinSeconds))
            signalCompletion()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeImmediately = completion.withLock { state -> Bool in
                switch state {
                case .signalled, .done:
                    state = .done
                    return true
                case .idle, .waiting:
                    state = .waiting(continuation)
                    return false
                }
            }
            if resumeImmediately { continuation.resume() }
        }
        deadline.cancel()
    }

    /// Returns what was captured. The drain threads have already read each
    /// stream to EOF (or the deadline passed and we keep what arrived), so
    /// there is nothing left to read here — and reading would race the thread
    /// that still owns the descriptor.
    func finish() -> (stdout: String, stderr: String) {
        (standardOutput.buffer.text(), standardError.buffer.text())
    }

    /// Releases the read ends on the path where the child never launched, so
    /// no drain thread was ever started. The write ends belong to Subprocess
    /// from the moment they are handed over.
    func discard() {
        close(standardOutput.readEnd)
        close(standardError.readEnd)
    }

    /// Reads one stream to EOF, then closes it. The descriptor's lifetime
    /// belongs to this thread: closing it from elsewhere while this read is
    /// parked would risk the number being reused under us.
    ///
    /// No deadline here. A thread still parked on a write end some unrelated
    /// process leaked costs one thread; the run itself is already bounded by
    /// the caller's deadline, so this can never hold up a job.
    private func drainToEOF(_ stream: Stream) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = read(stream.readEnd, &chunk, chunk.count)
            if bytesRead > 0 {
                stream.buffer.append(Data(chunk[0..<bytesRead]))
                continue
            }
            if bytesRead == -1 && errno == EINTR { continue }
            break
        }
        close(stream.readEnd)
    }

    private func noteStreamClosed() {
        let remaining = openStreams.withLock { count -> Int in
            count -= 1
            return count
        }
        if remaining == 0 { signalCompletion() }
    }

    /// Wakes the awaiting task, or records that it should not wait at all if
    /// it has not parked yet.
    private func signalCompletion() {
        let waiter = completion.withLock { state -> CheckedContinuation<Void, Never>? in
            switch state {
            case .idle:
                state = .signalled
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .signalled, .done:
                return nil
            }
        }
        waiter?.resume()
    }
}
