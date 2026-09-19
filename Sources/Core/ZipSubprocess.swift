// Core/ZipSubprocess.swift
//
// The one subprocess primitive for every `/usr/bin/zip` and
// `/usr/bin/unzip` invocation in the codebase.
//
// This file replaces `ZipProcessSerialization.swift`. That file held a
// process-wide lock, an EFAULT retry and a `makeZipProcess()` factory. All
// three existed to make Foundation's `Process` safe under concurrent spawns.
// `swift-subprocess` does not have those races, so the mitigations have
// nothing left to mitigate and are gone.
//
// One property from that file stays, because it is not a `Process` defect.
// `zipProcessEnvironment` reads the parent environment ONCE. A spawn that
// lets the library read the environment for it becomes an unsynchronized
// reader of a structure that `setenv` reallocates, and several test suites
// write environment variables while Swift Testing runs them concurrently.
// The observed failure was a SIGSEGV in `_ProcessInfo.environment.getter`
// under `Process.run()`, reported as `Bad pointer dereference at 0x210`.
// A snapshot does not remove the read, it removes the repetition: one read
// for the process instead of one for each spawn. `zip` and `unzip` do not
// consult the environment, so their behaviour does not change.
// `ZipProcessEnvironmentTests` fails if a zip spawn stops passing it.

import Foundation
import Subprocess
import SystemPackage

/// Exit status and captured stdout of a zip subprocess run.
public struct ZipProcessResult: Sendable {
    public let terminationStatus: Int32
    public let stdout: Data

    public init(terminationStatus: Int32, stdout: Data) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
    }
}

/// The parent environment, read once for the lifetime of the process.
/// See the file header for why this is a snapshot.
private let zipProcessEnvironment: [Environment.Key: String] = {
    var custom: [Environment.Key: String] = [:]
    for (key, value) in ProcessInfo.processInfo.environment {
        guard let environmentKey = Environment.Key(rawValue: key) else { continue }
        custom[environmentKey] = value
    }
    return custom
}()

/// Cap on captured stdout. Matches the per-entry ceiling the upload
/// validator enforces (`ZipUploadLimits.maxEntryUncompressedBytes`), which is
/// the largest single payload `unzip -p` can legitimately produce here.
/// Subprocess throws when a child exceeds the cap, so an archive that evades
/// the validator fails loudly instead of being read into the server's memory.
private let zipOutputLimitBytes = 64 * 1024 * 1024

/// Runs a zip/unzip subprocess and captures stdout.
///
/// stdout is always captured, so a caller that ignores it still cannot
/// deadlock the child against a pipe nobody drains. stderr is discarded:
/// every call site discarded it before, and `zip`'s diagnostics are not
/// reported to a user.
///
/// A non-zero exit is a normal result here, not an error. `unzip -Z1` exits
/// 11 when no entry matches, and `listZipContents` treats that as an empty
/// archive rather than a failure.
public func runZipProcess(
    executablePath: String,
    arguments: [String],
    workingDirectory: URL? = nil
) async throws -> ZipProcessResult {
    guard FileManager.default.fileExists(atPath: executablePath) else {
        throw ZipArchiverError.executableNotFound(executablePath)
    }
    let result = try await Subprocess.run(
        .path(FilePath(executablePath)),
        arguments: Arguments(arguments),
        environment: .custom(zipProcessEnvironment),
        workingDirectory: workingDirectory.map { FilePath($0.path) },
        output: .data(limit: zipOutputLimitBytes),
        error: .discarded
    )
    return ZipProcessResult(
        terminationStatus: zipExitCode(of: result.terminationStatus),
        stdout: result.standardOutput
    )
}

/// Runs a zip/unzip subprocess and throws when it exits non-zero.
/// For the callers that treat any failure as fatal.
public func runZipProcessExpectingSuccess(
    executablePath: String,
    arguments: [String],
    workingDirectory: URL? = nil
) async throws {
    let result = try await runZipProcess(
        executablePath: executablePath,
        arguments: arguments,
        workingDirectory: workingDirectory
    )
    guard result.terminationStatus == 0 else {
        throw ZipArchiverError.processFailed(executablePath, result.terminationStatus)
    }
}

/// Flattens a `TerminationStatus` to the `Int32` the call sites compare
/// against 0, with a signalled child reported as `128 + signal`.
private func zipExitCode(of status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code):
        return Int32(code)
    case .signaled(let signal):
        return 128 + Int32(signal)
    }
}
