// Core/ZipArchiver.swift
//
// Async helpers for ZIP creation and extraction via subprocess.
// Wraps /usr/bin/zip and /usr/bin/unzip (consistent with existing codebase usage).
//
// Lives in `Core` (v0.4.178+) so both `chickadee-server` and the
// `chickadee-runner` worker share one implementation.  Before the
// lift, the worker had its own `nonisolated func unzip(_:to:)` on
// `RunnerDaemon` that did a naked `Process.run()` — vulnerable to
// the same Foundation Process EFAULT race that ZipArchiver mitigates
// on the server side.
//
// All functions are free (not methods) to keep callsites clean.
// Process execution uses withCheckedThrowingContinuation + terminationHandler;
// no DispatchQueue bridging is needed because process setup is non-blocking
// and Foundation calls terminationHandler from its own internal monitoring queue.
//
// The two mitigations against the Foundation Process EFAULT race
// (process-wide lock + run-with-retry) live in
// `ZipProcessSerialization.swift` so every zip subprocess in the
// codebase shares the same lock.

import Foundation

// MARK: - Errors

public enum ZipArchiverError: Error, CustomStringConvertible {
    case processFailed(String, Int32)
    case executableNotFound(String)
    case pathTraversalDetected(String)

    public var description: String {
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
public func createZipArchive(sourceDir: URL, outputPath: String) async throws {
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
public func extractZipArchive(zipPath: String, into destinationDir: URL) async throws {
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
public func listZipContents(zipPath: String) throws -> [String] {
    guard FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
        throw ZipArchiverError.executableNotFound("/usr/bin/unzip")
    }
    // Serialize the entire Process lifecycle (see ZipProcessSerialization.swift).
    // Sync path holds the lock across read + wait too since both touch
    // the same Pipe / Process state.
    return try withZipProcessLock {
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
        // ZipProcessSerialization.swift).  Released after spawn;
        // terminationHandler runs on Foundation's queue and resumes the
        // continuation independently.
        acquireZipProcessLock()
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
            releaseZipProcessLock()
        } catch {
            releaseZipProcessLock()
            continuation.resume(throwing: error)
        }
    }
}
