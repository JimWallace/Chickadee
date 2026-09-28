// Sources/APIServer/Services/SupervisedProcess.swift
//
// One long-lived child process, launched through swift-subprocess, with its
// stdout and stderr appended to a log file. The local-runner autostart uses it
// for a `chickadee-runner` held for the server's whole lifetime.
//
// It replaces the last Foundation `Process` in the repository. Foundation
// detects a child's exit through a socket the child inherits, and concurrent
// Foundation launches leak those sockets into each other's children, so one
// child's exit can stay invisible for as long as another lives
// (docs/ci-flakiness.md, Family 6). swift-subprocess closes every descriptor
// above stderr in the child and watches the exit with a pidfd.
//
// A long-lived child is a `Subprocess.run` inside a task: the run returns when
// the child exits, and cancelling the task is how `stop()` ends it, through
// the teardown sequence (SIGTERM, then SIGINT, then SIGKILL).

import Foundation
import Subprocess
import Synchronization
import SystemPackage

final class SupervisedProcess: Sendable {
    /// How the child ended: its status, or the error that kept it from
    /// starting.
    typealias Outcome = Result<TerminationStatus, any Error>

    private let hasExited: Atomic<Bool>
    private let task: Mutex<Task<Void, Never>?>

    private init() {
        hasExited = Atomic(false)
        task = Mutex(nil)
    }

    /// False once the child has exited or failed to start.
    var isRunning: Bool {
        !hasExited.load(ordering: .acquiring)
    }

    /// Launches `executable` and returns at once. `onExit` runs once, when the
    /// child exits, fails to start, or is stopped.
    ///
    /// The child gets exactly `environment`, not the server's own. When the
    /// log file cannot be opened, the output is discarded rather than the
    /// launch refused, as the Foundation launch did.
    static func start(
        executable: FilePath,
        arguments: [String],
        environment: [String: String],
        workingDirectory: FilePath,
        logPath: FilePath,
        onExit: @escaping @Sendable (Outcome) -> Void
    ) throws -> SupervisedProcess {
        let output = try openLog(at: logPath)
        let errorOutput: FileDescriptor
        do {
            errorOutput = try duplicateCloseOnExec(output)
        } catch {
            try? output.close()
            throw error
        }

        var options = PlatformOptions()
        // SIGTERM lets the runner finish its current report; SIGINT is the
        // second request the old launch sent; the sequence always ends in
        // SIGKILL.
        options.teardownSequence = [
            .gracefulShutDown(allowedDurationToNextStep: .seconds(2)),
            .send(signal: .interrupt, allowedDurationToNextStep: .seconds(1)),
        ]
        let platformOptions = options
        let childEnvironment = subprocessEnvironment(environment)

        let process = SupervisedProcess()
        let runTask = Task {
            let outcome: Outcome
            do {
                let result = try await Subprocess.run(
                    .path(executable),
                    arguments: Arguments(arguments),
                    environment: .custom(childEnvironment),
                    workingDirectory: workingDirectory,
                    platformOptions: platformOptions,
                    input: .none,
                    output: .fileDescriptor(output, closeAfterSpawningProcess: true),
                    error: .fileDescriptor(errorOutput, closeAfterSpawningProcess: true)
                )
                outcome = .success(result.terminationStatus)
            } catch {
                outcome = .failure(error)
            }
            process.hasExited.store(true, ordering: .releasing)
            onExit(outcome)
        }
        process.task.withLock { $0 = runTask }
        return process
    }

    /// Stops the child and returns once it has exited and been reaped.
    func stop() async {
        guard let runTask = task.withLock({ $0 }) else { return }
        runTask.cancel()
        await runTask.value
    }

    /// Opens `path` for appending, close-on-exec, creating it if needed.
    /// Falls back to `/dev/null`, so a missing log directory never stops the
    /// launch.
    private static func openLog(at path: FilePath) throws -> FileDescriptor {
        let options: FileDescriptor.OpenOptions = [.append, .create, .closeOnExec]
        if let log = try? FileDescriptor.open(path, .writeOnly, options: options, permissions: [.ownerReadWrite]) {
            return log
        }
        return try FileDescriptor.open("/dev/null", .writeOnly, options: [.closeOnExec])
    }

    /// A second descriptor for the same file, created close-on-exec in one
    /// step, so no concurrent launch can inherit it.
    private static func duplicateCloseOnExec(_ descriptor: FileDescriptor) throws -> FileDescriptor {
        let duplicate = fcntl(descriptor.rawValue, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw Errno(rawValue: errno) }
        return FileDescriptor(rawValue: duplicate)
    }

    /// Bridges `[String: String]` to Subprocess's keyed environment, as
    /// `PersonalizationEvaluator` does. The module selector is needed because
    /// `Environment` is also a Vapor type.
    private static func subprocessEnvironment(
        _ environment: [String: String]
    ) -> [Subprocess::Environment.Key: String] {
        var custom: [Subprocess::Environment.Key: String] = [:]
        for (key, value) in environment {
            guard let environmentKey = Subprocess::Environment.Key(rawValue: key) else { continue }
            custom[environmentKey] = value
        }
        return custom
    }
}
