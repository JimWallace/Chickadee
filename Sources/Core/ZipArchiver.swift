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

public import Foundation

// MARK: - Errors

public enum ZipArchiverError: Error, CustomStringConvertible {
    case processFailed(String, Int32)
    case executableNotFound(String)
    case pathTraversalDetected(String)
    case outputAlreadyExists(String)
    /// The archive's directory declares more than `ZipExtractionLimits`
    /// allows, or could not be read to find out.
    case extractionLimitExceeded(String)

    public var description: String {
        switch self {
        case .processFailed(let cmd, let code):
            return "\(cmd) exited with status \(code)"
        case .executableNotFound(let path):
            return "Executable not found: \(path)"
        case .pathTraversalDetected(let entry):
            return "Zip entry would escape destination directory: \(entry)"
        case .outputAlreadyExists(let path):
            return "Zip output path already exists: \(path)"
        case .extractionLimitExceeded(let detail):
            return "Zip archive exceeds the extraction limit: \(detail)"
        }
    }
}

// MARK: - Extraction limits

/// The most an archive may unpack to (#2898). A small deflated archive can
/// expand about 1000:1, so the upload limit alone does not bound the disk an
/// extraction writes.
public struct ZipExtractionLimits: Sendable, Equatable {
    public let maxTotalUncompressedBytes: Int
    public let maxEntryCount: Int

    public init(maxTotalUncompressedBytes: Int, maxEntryCount: Int) {
        self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
        self.maxEntryCount = maxEntryCount
    }

    /// A student submission on the runner: the server's test-setup upload
    /// total (`ZipUploadLimits.default`), and an entry count no real
    /// submission approaches.
    public static let submission = ZipExtractionLimits(
        maxTotalUncompressedBytes: 256 * 1024 * 1024, maxEntryCount: 10_000)
}

/// The entry count and total uncompressed size in `unzip -Zt` output
/// ("2 files, 3000003 bytes uncompressed, 2926 bytes compressed:  99.9%"),
/// or nil when the line is not there.
func zipDirectoryTotals(_ text: String) -> (entries: Int, uncompressedBytes: Int)? {
    let pattern = /(\d+) files?, (\d+) bytes? uncompressed/
    guard let match = text.firstMatch(of: pattern),
        let entries = Int(match.output.1), let bytes = Int(match.output.2)
    else { return nil }
    return (entries, bytes)
}

/// Refuses an archive whose directory declares more than `limits`, before
/// anything is written. Fails closed: an archive whose totals cannot be read
/// is refused too.
func requireWithinExtractionLimits(zipPath: String, limits: ZipExtractionLimits) async throws {
    let result = try await runZipProcess(executablePath: "/usr/bin/unzip", arguments: ["-Zt", zipPath])
    guard result.terminationStatus == 0,
        let totals = zipDirectoryTotals(String(data: result.stdout, encoding: .utf8) ?? "")
    else {
        throw ZipArchiverError.extractionLimitExceeded("the archive directory could not be read")
    }
    guard totals.entries <= limits.maxEntryCount else {
        throw ZipArchiverError.extractionLimitExceeded(
            "\(totals.entries) entries, limit \(limits.maxEntryCount)")
    }
    guard totals.uncompressedBytes <= limits.maxTotalUncompressedBytes else {
        throw ZipArchiverError.extractionLimitExceeded(
            "\(totals.uncompressedBytes) bytes uncompressed, limit \(limits.maxTotalUncompressedBytes)")
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
///
/// The output path must not exist. `zip -r` adds to an existing archive
/// instead of replacing it, so a reused path would silently merge two
/// archives. Callers pass a fresh, unique path (#2767).
public func createZipArchive(sourceDir: URL, outputPath: String) async throws {
    guard !FileManager.default.fileExists(atPath: outputPath) else {
        throw ZipArchiverError.outputAlreadyExists(outputPath)
    }
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
/// path stays inside `destinationDir` before invoking the extractor. With
/// `limits`, also refuses an archive whose directory declares more entries or
/// uncompressed bytes than they allow (#2898). Pass them for an archive an
/// untrusted user built.
public func extractZipArchive(
    zipPath: String, into destinationDir: URL, limits: ZipExtractionLimits? = nil
) async throws {
    if let limits {
        try await requireWithinExtractionLimits(zipPath: zipPath, limits: limits)
    }
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
