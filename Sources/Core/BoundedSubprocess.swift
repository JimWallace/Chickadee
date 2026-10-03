// Core/BoundedSubprocess.swift
//
// One child, run once, with a deadline (#1792). Three call sites used to write
// this by hand: the worker's MIME detector and capability probes, and the
// server's personalization evaluator. Each raced `Subprocess.run` against a
// sleep in a task group, cancelled the loser, drained the group, and kept a
// private two-case enum and a private exit-code flattener. What differed was
// the parameters, not the logic.
//
// The worker's script launch (`executeScriptLaunch`) is not one of them: it
// truncates output instead of throwing, and reports a signal as a negated
// exit code, which `Tests/Fixtures/output-contract.json` pins.

import Subprocess
import SystemPackage

/// How long a bounded run may take, how much it may print, and how long its
/// process group has to exit after SIGTERM before SIGKILL.
public struct BoundedRunLimits: Sendable {
    public let timeout: Duration
    /// Cap on each captured stream, in bytes. Subprocess throws past it.
    public let outputLimit: Int
    public let teardownGrace: Duration

    public init(timeout: Duration, outputLimit: Int, teardownGrace: Duration) {
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.teardownGrace = teardownGrace
    }
}

/// What a bounded run printed, and how it ended.
public struct BoundedRunResult: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String
    /// The status as a shell reports it (`TerminationStatus.shellExitCode`).
    public let exitCode: Int32
}

extension TerminationStatus {
    /// The status as a shell reports it: the exit code, or `128 + signal` for
    /// a child a signal ended, so a killed child cannot be mistaken for one
    /// that exited with a small code.
    public var shellExitCode: Int32 {
        switch self {
        case .exited(let code):
            return Int32(code)
        case .signaled(let signal):
            return 128 + Int32(signal)
        }
    }
}

/// Runs `executable` once and returns what it printed, or nil when it was
/// still running at `limits.timeout`.
///
/// The child gets its own session, so the teardown reaches anything it put in
/// the background and nothing else: SIGTERM to its process group, then the
/// SIGKILL Subprocess always appends after `limits.teardownGrace`. Cancelling
/// the run is what starts the teardown; cancelling the sleep only ends it. The
/// drain swallows the cancelled task's error, so it cannot become the result
/// of a run that already finished.
///
/// `environment` is everything the child sees; nil inherits the parent's.
///
/// Throws when the child cannot be spawned or prints more than
/// `limits.outputLimit` on either stream. A non-zero exit is a result, not an
/// error.
public func runBounded(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    workingDirectory: String? = nil,
    limits: BoundedRunLimits
) async throws -> BoundedRunResult? {
    let childEnvironment: Subprocess::Environment
    if let environment {
        // `Environment.Key`'s failable initializer never fails, so no
        // variable is dropped here.
        var keyed: [Subprocess::Environment.Key: String] = [:]
        for (name, value) in environment {
            if let key = Subprocess::Environment.Key(rawValue: name) { keyed[key] = value }
        }
        childEnvironment = .custom(keyed)
    } else {
        childEnvironment = .inherit
    }
    let childDirectory = workingDirectory.map { FilePath($0) }
    var options = PlatformOptions()
    options.createSession = true
    options.teardownSequence = [
        .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: limits.teardownGrace)
    ]
    let platformOptions = options

    return try await withThrowingTaskGroup(of: BoundedRunResult?.self) { group in
        group.addTask {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(arguments),
                environment: childEnvironment,
                workingDirectory: childDirectory,
                platformOptions: platformOptions,
                output: .string(limit: limits.outputLimit),
                error: .string(limit: limits.outputLimit)
            )
            return BoundedRunResult(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                exitCode: result.terminationStatus.shellExitCode)
        }
        group.addTask {
            try await Task.sleep(for: limits.timeout)
            return nil
        }
        // The first task to finish: the run's result, or the sleep's nil.
        let first = try await group.next()
        group.cancelAll()
        while (try? await group.next()) != nil {}
        return first.flatMap { $0 }
    }
}
