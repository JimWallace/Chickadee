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
// Every spawn goes through `runZipProcess` in `ZipSubprocess.swift`, which
// runs on swift-subprocess. The process-wide lock and the EFAULT retry that
// used to guard these calls are gone with Foundation's `Process`; see that
// file for what remains and why.

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
/// Equivalent to: cd <sourceDir> && /usr/bin/zip -q -r <outputPath> .
///
/// `-q` (quiet) matters: without it `zip` prints one "adding: …" line per
/// file, and for a large tree (e.g. a data-heavy personal-data export) that
/// output is what used to overflow the discarded-output buffer.  The real
/// deadlock guard is `runZipProcess` capturing and bounding child output,
/// but staying quiet avoids generating megabytes of output nobody reads.
public func createZipArchive(sourceDir: URL, outputPath: String) async throws {
    try await runZipProcessExpectingSuccess(
        executablePath: "/usr/bin/zip",
        arguments: ["-q", "-r", outputPath, "."],
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
    let entries = try await listZipContents(zipPath: zipPath)
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
    try await runZipProcessExpectingSuccess(
        executablePath: "/usr/bin/unzip",
        arguments: ["-q", zipPath, "-d", destinationDir.path]
    )
}

/// Returns the list of filenames inside a ZIP archive.
/// Uses `unzip -Z1` (zipinfo one-name-per-line format).
public func listZipContents(zipPath: String) async throws -> [String] {
    let result = try await runZipProcess(
        executablePath: "/usr/bin/unzip",
        arguments: ["-Z1", zipPath]
    )
    // unzip -Z1 exits 0 (OK) or 11 (no matching files) — both are fine here.
    let output = String(data: result.stdout, encoding: .utf8) ?? ""
    return output.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}
