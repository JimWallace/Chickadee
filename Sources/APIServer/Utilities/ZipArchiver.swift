// APIServer/Utilities/ZipArchiver.swift
//
// Async helpers for ZIP creation and extraction via subprocess.
// Wraps /usr/bin/zip and /usr/bin/unzip (consistent with existing codebase usage).
//
// All functions are free (not methods) to keep callsites clean.
// Process execution is offloaded to a background DispatchQueue via
// withCheckedThrowingContinuation so the Vapor event loop is not blocked.

import Foundation

// MARK: - Errors

enum ZipArchiverError: Error, CustomStringConvertible {
    case processFailed(String, Int32)
    case executableNotFound(String)

    var description: String {
        switch self {
        case .processFailed(let cmd, let code):
            return "\(cmd) exited with status \(code)"
        case .executableNotFound(let path):
            return "Executable not found: \(path)"
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
func extractZipArchive(zipPath: String, into destinationDir: URL) async throws {
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    try await runZipProcess(
        executablePath: "/usr/bin/unzip",
        arguments: ["-q", zipPath, "-d", destinationDir.path]
    )
}

/// Returns the list of filenames inside a ZIP archive.
/// Uses `unzip -Z1` (zipinfo one-name-per-line format).
func listZipContents(zipPath: String) throws -> [String] {
    let proc = Process()
    guard FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
        throw ZipArchiverError.executableNotFound("/usr/bin/unzip")
    }
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments     = ["-Z1", zipPath]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError  = Pipe() // discard
    try proc.run()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    // unzip -Z1 exits 0 (OK) or 11 (no matching files) — both are fine here.
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n", omittingEmptySubsequences: true)
                 .map(String.init)
}

// MARK: - Private helper

/// Runs an executable asynchronously. Errors if exit status != 0.
private func runZipProcess(executablePath: String,
                           arguments: [String],
                           workingDirectory: URL? = nil) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard FileManager.default.fileExists(atPath: executablePath) else {
                    continuation.resume(throwing: ZipArchiverError.executableNotFound(executablePath))
                    return
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executablePath)
                proc.arguments     = arguments
                if let dir = workingDirectory {
                    proc.currentDirectoryURL = dir
                }
                proc.standardOutput = Pipe() // discard stdout
                proc.standardError  = Pipe() // discard stderr
                proc.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ZipArchiverError.processFailed(
                            executablePath, process.terminationStatus))
                    }
                }
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
