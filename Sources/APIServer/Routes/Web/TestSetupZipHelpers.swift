// APIServer/Routes/Web/TestSetupZipHelpers.swift
//
// Zip-archive read/mutate helpers for the test setup file: list, extract,
// add, replace, batch-apply, remove, response-build, content-type, and
// the publish-time `createRunnerSetupZip` step plus the support-file
// materializer that copies non-test/non-notebook entries into the shared
// directory.  Extracted from AssignmentHelpers.swift (issue #442) — no
// behaviour changes.

import Vapor
import Foundation

enum ScriptZipError: Error {
    case fileNotFound(String)
    case invalidUTF8
    case zipFailed
}

struct RunnerSetupPackage {
    let testSuites: [ConfiguredSuiteEntry]
    let hasMakefile: Bool
}

func listZipEntries(zipPath: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", zipPath]

    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return []
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text
        .split(separator: "\n")
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
        .filter { !$0.isEmpty && !$0.hasSuffix("/") }
}

// MARK: - Script zip read/write helpers

/// Reads a single file from a test setup zip and returns it as a UTF-8 string.
/// Returns `nil` if the entry does not exist.
func readScriptFromZip(zipPath: String, filename: String) -> String? {
    guard let data = extractZipEntry(zipPath: zipPath, entryName: filename) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Replaces or adds a file in the test setup zip with new UTF-8 text content.
///
/// Strategy: extract all entries to a temp directory, overwrite/add the target
/// file, delete the original zip, then re-create it from the temp directory.
func updateScriptInZip(zipPath: String, filename: String, content: String) throws {
    guard let contentData = content.data(using: .utf8) else {
        throw ScriptZipError.invalidUTF8
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("chickadee_zip_edit_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    // Extract all current entries.
    for entry in listZipEntries(zipPath: zipPath) {
        guard let data = extractZipEntry(zipPath: zipPath, entryName: entry) else { continue }
        let dest = tempDir.appendingPathComponent(entry)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    // Write the new/updated file.
    let fileURL = tempDir.appendingPathComponent(filename)
    try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contentData.write(to: fileURL)

    // Remove old zip and re-create from temp directory.
    try? fm.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    zip.standardOutput = Pipe()
    zip.standardError  = Pipe()
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
}

/// Applies a batch of script writes and deletions to a test setup zip in a
/// single extract-then-repack cycle.  Cheaper than repeated single-file
/// updates when regenerating a whole pattern family at once.
///
/// - `writes`: filename → UTF-8 content.  Overwrites if the entry exists.
/// - `deletions`: filenames to remove.  Missing entries are silently ignored.
///   Applied before writes, so the same filename in both collections results
///   in the `writes` value winning.
func applyScriptChangesToZip(
    zipPath: String,
    writes: [String: String],
    deletions: [String]
) throws {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("chickadee_zip_apply_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let deletionSet = Set(deletions)

    for entry in listZipEntries(zipPath: zipPath) {
        guard !deletionSet.contains(entry) else { continue }
        guard let data = extractZipEntry(zipPath: zipPath, entryName: entry) else { continue }
        let dest = tempDir.appendingPathComponent(entry)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    for (filename, content) in writes {
        guard let contentData = content.data(using: .utf8) else {
            throw ScriptZipError.invalidUTF8
        }
        let dest = tempDir.appendingPathComponent(filename)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contentData.write(to: dest)
    }

    try? fm.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    zip.standardOutput = Pipe()
    zip.standardError  = Pipe()
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
}

/// Removes a file from the test setup zip.
/// Throws `ScriptZipError.fileNotFound` if the entry does not exist.
func removeScriptFromZip(zipPath: String, filename: String) throws {
    let entries = listZipEntries(zipPath: zipPath)
    guard entries.contains(filename) else {
        throw ScriptZipError.fileNotFound(filename)
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("chickadee_zip_edit_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    // Extract all entries except the one to remove.
    for entry in entries where entry != filename {
        guard let data = extractZipEntry(zipPath: zipPath, entryName: entry) else { continue }
        let dest = tempDir.appendingPathComponent(entry)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    // Remove old zip and re-create.
    try? fm.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    zip.standardOutput = Pipe()
    zip.standardError  = Pipe()
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
}

func extractZipEntry(zipPath: String, entryName: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", zipPath, entryName]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return data
}

func buildFileResponse(data: Data, filename: String) -> Response {
    var headers = HTTPHeaders()
    headers.contentType = contentType(for: filename)
    headers.add(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}

func contentType(for filename: String) -> HTTPMediaType {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "ipynb", "json":
        return .json
    case "py", "r", "sh", "bash", "zsh", "rb", "pl", "js", "php", "txt", "md", "csv":
        return .plainText
    default:
        return HTTPMediaType(type: "application", subType: "octet-stream")
    }
}

func createRunnerSetupZip(
    suiteFiles: [File],
    suiteConfigJSON: String?,
    zipPath: String
) throws -> RunnerSetupPackage {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("chickadee_runner_setup_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    var seenNames: Set<String> = []
    var storedNameByIndex: [Int: String] = [:]
    for (index, file) in suiteFiles.enumerated() {
        let data = Data(file.data.readableBytesView)
        guard !data.isEmpty else { continue }
        let rawName = file.filename.isEmpty ? "suite-file-\(index + 1)" : file.filename
        let baseName = sanitizeSuiteFilename(rawName)
        let finalName: String
        if !seenNames.contains(baseName) {
            finalName = baseName
        } else {
            let ext = URL(fileURLWithPath: baseName).pathExtension
            let stem = (baseName as NSString).deletingPathExtension
            var suffix = 2
            var candidate = baseName
            while seenNames.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                suffix += 1
            }
            finalName = candidate
        }
        seenNames.insert(finalName)
        try data.write(to: tempDir.appendingPathComponent(finalName))
        storedNameByIndex[index] = finalName
    }

    // Neither assignment.ipynb nor solution.ipynb belong in the runner zip.
    //
    // assignment.ipynb is the starter template served to students via
    // JupyterLite (from notebooks/{setupID}/ on disk).  The runner doesn't
    // need it — the student provides their own submission.  Having it in the
    // working directory forces the runner to delete it before tests run so
    // grading scripts don't see two notebooks.
    //
    // solution.ipynb is persisted separately as a validation-submission
    // artifact.  Including it would produce duplicate .py definitions.

    let testSuites = try buildSuiteEntries(
        suiteFiles: suiteFiles,
        storedNameByIndex: storedNameByIndex,
        suiteConfigJSON: suiteConfigJSON
    )

    if storedNameByIndex.isEmpty {
        try writeEmptyZip(to: zipPath)
    } else {
        // Rebuilding an existing setup zip must start from a clean archive.
        // `zip -r existing.zip .` updates/adds entries but does not remove files
        // that are absent from the new source directory, which makes deleted
        // suite/support files reappear on the next edit.
        try? fm.removeItem(atPath: zipPath)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-q", "-r", zipPath, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw WebAssignmentError.internalFailure(reason: "Failed to package setup zip")
        }
    }
    let hasMakefile = storedNameByIndex.values.contains {
        let n = $0.lowercased()
        return n == "makefile" || n == "gnumakefile"
    }
    return RunnerSetupPackage(testSuites: testSuites, hasMakefile: hasMakefile)
}

private func writeEmptyZip(to path: String) throws {
    let emptyZip = Data([
        0x50, 0x4b, 0x05, 0x06,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00
    ])
    try emptyZip.write(to: URL(fileURLWithPath: path))
}

// MARK: - Support file extraction

/// Extracts "support" files (zip entries that are neither test suite scripts nor the
/// canonical notebooks) to `{testSetupsDirectory}/shared/{setupID}/`.
///
/// Called after every test setup create/update so the shared directory always reflects
/// the current zip contents. The runner is unaffected — it re-extracts the full zip
/// to a temp directory per job.
func extractSupportFilesToSharedDirectory(
    zipPath: String,
    setupID: String,
    testSuiteScripts: Set<String>,
    testSetupsDirectory: String
) {
    let reservedNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]
    let allEntries = listZipEntries(zipPath: zipPath)
    let supportNames = allEntries.filter {
        !testSuiteScripts.contains($0) && !reservedNames.contains($0)
    }

    let sharedDir = testSetupsDirectory + "shared/\(setupID)/"
    let fm = FileManager.default
    do {
        // Always remove the stale shared dir before re-extracting so a support
        // file removed on edit doesn't linger (and so student symlinks to it
        // become visibly broken rather than silently stale).
        if fm.fileExists(atPath: sharedDir) {
            try fm.removeItem(atPath: sharedDir)
        }
        guard !supportNames.isEmpty else { return }
        try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        for name in supportNames {
            guard let data = extractZipEntry(zipPath: zipPath, entryName: name) else { continue }
            let destination = URL(fileURLWithPath: sharedDir + name)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
        }
    } catch {
        // Non-fatal: support files are a convenience; log and continue.
        // (Structured logging not available in a free function; print suffices here.)
        print("[chickadee] Warning: failed to extract support files for \(setupID): \(error)")
    }
}
