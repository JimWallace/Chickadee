// APIServer/Utilities/ZipArchiver.swift
//
// Async helpers for ZIP creation and extraction via subprocess.
// Wraps /usr/bin/zip and /usr/bin/unzip (consistent with existing codebase usage).
//
// All functions are free (not methods) to keep callsites clean.
// Process execution uses withCheckedThrowingContinuation + terminationHandler;
// no DispatchQueue bridging is needed because process setup is non-blocking
// and Foundation calls terminationHandler from its own internal monitoring queue.
//
// Foundation's `Process` has a known race under concurrent invocation
// that surfaces as `NSPOSIXErrorDomain Code=14 "Bad address"` (EFAULT).
// The race spans more than just `posix_spawn` itself (Pipe allocation +
// child fd setup + spawn share global state) and reaches across the whole
// Process API surface — so even a tight intra-file lock can't fully fix
// it, because Process invocations originating elsewhere (test setup
// helpers, etc.) still race against ours.
//
// We use two complementary mitigations:
//   1. `zipProcessLock` serializes the entire zip Process lifecycle for
//      ZipArchiver-originated calls, so they never race each other.
//   2. `runProcessWithEFAULTRetry` retries `Process.run()` once on
//      transient EFAULT, with a brief sleep, to absorb cross-call races
//      we can't lock against.
// ZIP operations are infrequent (test setup upload, course bundle
// import, suite save), so the cost of both mitigations is negligible.

import Foundation

/// Process-wide lock held across the **entire** zip subprocess
/// lifecycle: Process / Pipe construction, property setting, `run()`,
/// and (for sync paths) the wait.  Async paths release the lock
/// inside the continuation closure once the spawn returns, which is
/// safe because Foundation's terminationHandler runs on its own queue.
private let zipProcessLock = NSLock()

/// Calls `proc.run()`, retrying once after a 10 ms backoff if it throws
/// `NSPOSIXErrorDomain` / `EFAULT` (Foundation Process race; see notes
/// at top of file).  `proc` must not have been started yet.
private func runProcessWithEFAULTRetry(_ proc: Process) throws {
    do {
        try proc.run()
    } catch let error as NSError
        where
        error.domain == NSPOSIXErrorDomain && error.code == Int(EFAULT)
    {
        Thread.sleep(forTimeInterval: 0.01)
        try proc.run()
    }
}

// MARK: - Errors

enum ZipArchiverError: Error, CustomStringConvertible {
    case processFailed(String, Int32)
    case executableNotFound(String)
    case pathTraversalDetected(String)

    var description: String {
        switch self {
        case .processFailed(let cmd, let code):
            return "\(cmd) exited with status \(code)"
        case .executableNotFound(let path):
            return "Executable not found: \(path)"
        case .pathTraversalDetected(let entry):
            return "Zip entry would escape destination directory: \(entry)"
        }
    }
}

// MARK: - Public API

/// Creates a ZIP archive from all contents of `sourceDir`.
/// The resulting archive contains paths relative to `sourceDir` (no parent dir prefix).
///
/// Equivalent to: cd <sourceDir> && /usr/bin/zip -r <outputPath> .
func createZipArchive(sourceDir: URL, outputPath: String) async throws {
    try await runZipProcess(
        executablePath: "/usr/bin/zip",
        arguments: ["-r", outputPath, "."],
        workingDirectory: sourceDir
    )
}

/// Extracts a ZIP archive into `destinationDir`, creating it if needed.
///
/// Equivalent to: /usr/bin/unzip -q <zipPath> -d <destinationDir>
///
/// Guards against zip-slip path traversal by validating every entry's resolved
/// path stays inside `destinationDir` before invoking the extractor.
func extractZipArchive(zipPath: String, into destinationDir: URL) async throws {
    // --- Zip-slip guard ---
    // List all entries first and reject any that would land outside destinationDir
    // after resolving ".."-style components or absolute paths.
    let entries = try listZipContents(zipPath: zipPath)
    let destStandardized = destinationDir.standardized
    // Canonical prefix with trailing slash so "/tmp/destfoo" ≠ "/tmp/dest".
    let destPrefix =
        destStandardized.path.hasSuffix("/")
        ? destStandardized.path
        : destStandardized.path + "/"
    for entry in entries {
        // Explicitly reject absolute paths (unzip -Z1 may produce these for
        // malformed archives even though modern unzip typically strips them).
        guard !entry.hasPrefix("/") else {
            throw ZipArchiverError.pathTraversalDetected(entry)
        }
        // Resolve ".." components lexically and confirm the result is still
        // inside the destination directory.
        let resolved = destStandardized.appendingPathComponent(entry).standardized.path
        guard resolved.hasPrefix(destPrefix) else {
            throw ZipArchiverError.pathTraversalDetected(entry)
        }
    }
    // --- Extraction ---
    try FileManager.default.createDirectory(
        at: destinationDir,
        withIntermediateDirectories: true)
    try await runZipProcess(
        executablePath: "/usr/bin/unzip",
        arguments: ["-q", zipPath, "-d", destinationDir.path]
    )
}

/// Returns the list of filenames inside a ZIP archive.
/// Uses `unzip -Z1` (zipinfo one-name-per-line format).
func listZipContents(zipPath: String) throws -> [String] {
    guard FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
        throw ZipArchiverError.executableNotFound("/usr/bin/unzip")
    }
    // Serialize the entire Process lifecycle (see zipProcessLock comment
    // at top of file).  Sync path holds the lock across read + wait too
    // since both touch the same Pipe / Process state.
    zipProcessLock.lock()
    defer { zipProcessLock.unlock() }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-Z1", zipPath]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = Pipe()  // discard
    try runProcessWithEFAULTRetry(proc)
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    // unzip -Z1 exits 0 (OK) or 11 (no matching files) — both are fine here.
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

// MARK: - Private helper

/// Runs an executable asynchronously. Errors if exit status != 0.
///
/// Process setup (property assignment + `run()`) is cheap and non-blocking.
/// The continuation is resumed by Foundation's `terminationHandler`, which is
/// called from Foundation's internal process-monitoring queue — no
/// DispatchQueue offloading is required.
private func runZipProcess(
    executablePath: String,
    arguments: [String],
    workingDirectory: URL? = nil
) async throws {
    guard FileManager.default.fileExists(atPath: executablePath) else {
        throw ZipArchiverError.executableNotFound(executablePath)
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // Serialize Process / Pipe construction + setup + spawn (see
        // zipProcessLock comment at top of file).  Released after spawn;
        // terminationHandler runs on Foundation's queue and resumes the
        // continuation independently.
        zipProcessLock.lock()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        if let dir = workingDirectory {
            proc.currentDirectoryURL = dir
        }
        proc.standardOutput = Pipe()  // discard stdout
        proc.standardError = Pipe()  // discard stderr
        proc.terminationHandler = { process in
            if process.terminationStatus == 0 {
                continuation.resume()
            } else {
                continuation.resume(
                    throwing: ZipArchiverError.processFailed(
                        executablePath, process.terminationStatus))
            }
        }
        do {
            try runProcessWithEFAULTRetry(proc)
            zipProcessLock.unlock()
        } catch {
            zipProcessLock.unlock()
            continuation.resume(throwing: error)
        }
    }
}
