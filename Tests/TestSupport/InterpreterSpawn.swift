// Tests/TestSupport/InterpreterSpawn.swift
//
// The one place the test suites spawn an interpreter.
//
// WHY A HELPER AND NOT FIFTY COPIES. Before this file, 39 test files built
// their own Foundation `Process` and spawned it, in two shapes repeated almost
// verbatim: an availability probe (`env <tool> --version`, check the exit
// status) and a script run (`env <interpreter> <script>` in a directory,
// capture the output). `ZipFixtureSupport` learned the same lesson for
// `/usr/bin/zip` after seventeen copies crashed the test process inside
// `Process.run()`.
//
// It also answers a live question rather than only tidying. `docs/ci-flakiness.md`
// Family 5 keeps "a subprocess storm" as an open lead, measured as 21 of
// APITests' 376 files both spawning `Process()` and naming a real interpreter.
// Routing every one of those through `swift-subprocess` removes the spawner
// that lead is about: Foundation's `Process` shares global state across Pipe
// allocation, child fd setup and spawn, which is the race the zip path needed
// a process-wide lock and an EFAULT retry to contain.
//
// Foundation `Process` survives in exactly three places across the whole
// repository, and each one is here because migrating it would delete what it
// exists to do. If you add a fourth, add it to this list.
//
//   * `Tests/CoreTests/PipeCloseOnExecTests.swift` — its subject IS Foundation
//     `Pipe` inheritance across a real `exec`.
//   * `Tests/WorkerTests/Support/LocalHTTPTestServer.swift` — a long-lived
//     server held past one call, which the collected API does not model.
//   * `Sources/APIServer/APIServerApp+Stores.swift` — the local-runner
//     autostart, which is the same long-lived shape: the server keeps the
//     child for its own lifetime rather than collecting a result.
//
// `ScriptRunnerTestSupport`'s spawn-retry harness used to be on this list.
// It is not any more: its retry absorbed a `posix_spawn` EAGAIN that only
// Foundation's `Process` surfaces, so the retry went and the throttle stayed
// (`runToolThrottled`).

import Foundation
import Subprocess
import SystemPackage

/// Exit status and captured streams of one tool run.
public struct ToolRun: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// The parent environment, read once for the lifetime of the test process.
///
/// Not an optimisation. A spawn that lets the library read the environment for
/// it becomes an unsynchronized reader of a structure `setenv` reallocates, and
/// several suites here write environment variables while Swift Testing runs
/// them concurrently. `Core/ZipSubprocess.swift` carries the same snapshot for
/// the same reason, and the failure it prevents is a SIGSEGV rather than a test
/// failure.
private let inheritedEnvironment: [Environment.Key: String] = {
    var custom: [Environment.Key: String] = [:]
    for (key, value) in ProcessInfo.processInfo.environment {
        guard let environmentKey = Environment.Key(rawValue: key) else { continue }
        custom[environmentKey] = value
    }
    return custom
}()

/// Cap on captured output. Generous for a `--version` banner or a generated
/// test script's stdout; Subprocess throws past it rather than letting a
/// runaway child consume the test process's memory.
private let toolOutputLimitBytes = 4 * 1024 * 1024

/// Runs `/usr/bin/env <argv>` and collects stdout and stderr.
///
/// A non-zero exit is a normal result, not an error: callers inspect
/// `ToolRun.exitCode`. Only a spawn failure throws.
public func runTool(
    _ argv: [String],
    workingDirectory: URL? = nil,
    extraEnvironment: [String: String] = [:],
    removingEnvironment: [String] = [],
    standardInput: String? = nil
) async throws -> ToolRun {
    var environment = inheritedEnvironment
    for (key, value) in extraEnvironment {
        guard let environmentKey = Environment.Key(rawValue: key) else { continue }
        environment[environmentKey] = value
    }
    for key in removingEnvironment {
        guard let environmentKey = Environment.Key(rawValue: key) else { continue }
        environment.removeValue(forKey: environmentKey)
    }

    var options = PlatformOptions()
    // setsid(2): a tool that backgrounds a child must not leave it behind when
    // the run ends, and a group-wide signal is safe only in the child's own
    // session.
    options.createSession = true

    // `.none` closes the child's stdin, which is what every call site that
    // passes no input wants: a reader then sees EOF instead of blocking.
    if let standardInput {
        let result = try await Subprocess.run(
            .path("/usr/bin/env"),
            arguments: Arguments(argv),
            environment: .custom(environment),
            workingDirectory: workingDirectory.map { FilePath($0.path) },
            platformOptions: options,
            input: .data(Data(standardInput.utf8)),
            output: .string(limit: toolOutputLimitBytes),
            error: .string(limit: toolOutputLimitBytes)
        )
        return ToolRun(
            stdout: result.standardOutput,
            stderr: result.standardError,
            exitCode: toolExitCode(of: result.terminationStatus)
        )
    }
    let result = try await Subprocess.run(
        .path("/usr/bin/env"),
        arguments: Arguments(argv),
        environment: .custom(environment),
        workingDirectory: workingDirectory.map { FilePath($0.path) },
        platformOptions: options,
        output: .string(limit: toolOutputLimitBytes),
        error: .string(limit: toolOutputLimitBytes)
    )
    return ToolRun(
        stdout: result.standardOutput,
        stderr: result.standardError,
        exitCode: toolExitCode(of: result.terminationStatus)
    )
}

/// Runs `/usr/bin/env <argv>` with stderr folded into stdout, the way a call
/// site that pointed both streams at ONE pipe used to see them.
///
/// Separate streams are the default because most call sites want them apart;
/// this exists for the ones that read an interpreter's banner without caring
/// which stream it came out on, and where concatenating after the fact would
/// lose the interleaving.
public func runToolCombiningStreams(
    _ argv: [String],
    workingDirectory: URL? = nil,
    removingEnvironment: [String] = []
) async throws -> ToolRun {
    var environment = inheritedEnvironment
    for key in removingEnvironment {
        guard let environmentKey = Environment.Key(rawValue: key) else { continue }
        environment.removeValue(forKey: environmentKey)
    }
    var options = PlatformOptions()
    options.createSession = true

    let result = try await Subprocess.run(
        .path("/usr/bin/env"),
        arguments: Arguments(argv),
        environment: .custom(environment),
        workingDirectory: workingDirectory.map { FilePath($0.path) },
        platformOptions: options,
        output: .string(limit: toolOutputLimitBytes),
        error: .combinedWithOutput
    )
    return ToolRun(
        stdout: result.standardOutput,
        stderr: "",
        exitCode: toolExitCode(of: result.terminationStatus)
    )
}

/// True when `tool` is installed and answers `arguments` with exit 0.
///
/// Never throws: an absent tool is the question being asked, not an error.
public func toolIsAvailable(_ tool: String, arguments: [String] = ["--version"]) async -> Bool {
    guard let run = try? await runTool([tool] + arguments) else { return false }
    return run.succeeded
}

/// Flattens a `TerminationStatus` to the `Int32` call sites compare against 0,
/// with a signalled child reported as `128 + signal`.
private func toolExitCode(of status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code):
        return Int32(code)
    case .signaled(let signal):
        return 128 + Int32(signal)
    }
}
