// APIServer/Routes/Web/TestSetupZipHelpers.swift
//
// Zip-archive read/mutate helpers for the test setup file: list, extract,
// add, replace, batch-apply, remove, response-build, content-type, and
// the publish-time `createRunnerSetupZip` step plus the support-file
// materializer that copies non-test/non-notebook entries into the shared
// directory.  Extracted from AssignmentHelpers.swift (issue #442) — no
// behaviour changes.

import Core
import Foundation
import Vapor

enum ScriptZipError: Error {
    case fileNotFound(String)
    case invalidUTF8
    case zipFailed
}

/// Packs `sourceDir` into `zipPath` via `/usr/bin/zip -q -r`, running
/// under the shared zip process lock (see `ZipProcessSerialization.swift`)
/// so it can't race the async helpers in `ZipArchiver.swift` or the
/// other sync zip helpers in this file.  Throws `ScriptZipError.zipFailed`
/// on any failure — caller decides whether to translate to a higher-level
/// error.
func repackZipFromDirectory(zipPath: String, sourceDir: URL) throws {
    // `/usr/bin/zip -r . ` aborts with "Nothing to do!" (exit 12) when the
    // source directory holds no files. An empty test setup is a legitimate
    // state — attaching personalization inputs to a brand-new assignment before
    // any test script exists, or deleting the last script — so emit a valid
    // empty archive rather than failing the whole save with a raw zip error.
    guard directoryContainsFile(sourceDir) else {
        try writeEmptyZip(at: zipPath)
        return
    }
    try withZipProcessLock {
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = sourceDir
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try runProcessWithEFAULTRetry(zip)
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
    }
}

/// True when `dir` contains at least one regular file (searched recursively).
/// `zip` has "nothing to do" — and exits non-zero — when this is false.
private func directoryContainsFile(_ dir: URL) -> Bool {
    guard
        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    else { return false }
    for case let url as URL in enumerator
    where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        return true
    }
    return false
}

/// Writes a valid, empty zip archive (a bare 22-byte End-Of-Central-Directory
/// record) to `zipPath`. `zip(1)` refuses to create an empty archive, so we
/// emit the canonical empty-zip bytes directly; `unzip` / `listZipEntries` read
/// it back as an archive with zero entries.
private func writeEmptyZip(at zipPath: String) throws {
    let endOfCentralDirectory: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
    try? FileManager.default.removeItem(atPath: zipPath)
    try Data(endOfCentralDirectory).write(to: URL(fileURLWithPath: zipPath))
}

// MARK: - Zip upload size guard

/// Upper bounds applied to a freshly-uploaded test-setup zip before it is
/// persisted.  Defaults are deliberately generous for legitimate course
/// material while small enough that a single malicious upload can't
/// exhaust the host's disk.  Per-entry plus total cover the two common
/// zip-bomb shapes: many small entries summing into a giant whole, or
/// one entry that expands wildly.
struct ZipUploadLimits {
    let maxTotalUncompressedBytes: Int
    let maxEntryUncompressedBytes: Int

    static let `default` = ZipUploadLimits(
        maxTotalUncompressedBytes: 256 * 1024 * 1024,
        maxEntryUncompressedBytes: 64 * 1024 * 1024
    )
}

enum ZipUploadValidationError: Error, CustomStringConvertible {
    case inspectionFailed
    case totalSizeExceeded(actualBytes: Int, limitBytes: Int)
    case entrySizeExceeded(name: String, actualBytes: Int, limitBytes: Int)

    var description: String {
        switch self {
        case .inspectionFailed:
            return "Could not read uploaded zip (corrupt or unsupported format)"
        case .totalSizeExceeded(let actual, let limit):
            return "Uploaded zip decompresses to \(actual) bytes; total limit is \(limit) bytes"
        case .entrySizeExceeded(let name, let actual, let limit):
            return "Zip entry '\(name)' decompresses to \(actual) bytes; per-entry limit is \(limit) bytes"
        }
    }
}

/// Inspects the supplied zip's declared uncompressed sizes via `unzip -v`
/// and throws if any entry — or the total — exceeds `limits`.  Runs
/// before extraction so a zip bomb can't waste disk on its way to being
/// rejected.  `unzip -v` parses table-of-entries delimited by a pair of
/// dashed separator lines; each entry has seven space-separated columns
/// (Length, Method, Size, Cmpr, Date, Time, CRC-32) before the name.
func validateZipUploadSize(zipPath: String, limits: ZipUploadLimits = .default) throws {
    let (status, data): (Int32, Data) = try withZipProcessLock {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-v", zipPath]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try runProcessWithEFAULTRetry(process)
        } catch {
            throw ZipUploadValidationError.inspectionFailed
        }
        let captured = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, captured)
    }
    guard status == 0,
        let text = String(data: data, encoding: .utf8)
    else {
        throw ZipUploadValidationError.inspectionFailed
    }

    var inEntries = false
    var total = 0
    for line in text.split(separator: "\n").map(String.init) {
        if line.hasPrefix("--------") {
            inEntries.toggle()
            continue
        }
        guard inEntries else { continue }
        let parts =
            line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count >= 8, let length = Int(parts[0]) else { continue }
        let name = parts.dropFirst(7).joined(separator: " ")
        if length > limits.maxEntryUncompressedBytes {
            throw ZipUploadValidationError.entrySizeExceeded(
                name: name, actualBytes: length,
                limitBytes: limits.maxEntryUncompressedBytes
            )
        }
        total += length
        if total > limits.maxTotalUncompressedBytes {
            throw ZipUploadValidationError.totalSizeExceeded(
                actualBytes: total,
                limitBytes: limits.maxTotalUncompressedBytes
            )
        }
    }
}

struct RunnerSetupPackage {
    let testSuites: [ConfiguredSuiteEntry]
    let hasMakefile: Bool
}

func listZipEntries(zipPath: String) -> [String] {
    let result: (Int32, Data)? = try? withZipProcessLock {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", zipPath]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try runProcessWithEFAULTRetry(process)
        let captured = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, captured)
    }
    guard let (status, data) = result, status == 0,
        let text = String(data: data, encoding: .utf8)
    else { return [] }
    return
        text
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
    try repackZipFromDirectory(zipPath: zipPath, sourceDir: tempDir)
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
    try repackZipFromDirectory(zipPath: zipPath, sourceDir: tempDir)
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
    try repackZipFromDirectory(zipPath: zipPath, sourceDir: tempDir)
}

func extractZipEntry(zipPath: String, entryName: String) -> Data? {
    let result: (Int32, Data)? = try? withZipProcessLock {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipPath, entryName]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try runProcessWithEFAULTRetry(process)
        let captured = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, captured)
    }
    guard let (status, data) = result, status == 0 else { return nil }
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
    case "py", "r", "lua", "sh", "bash", "zsh", "rb", "pl", "js", "php", "txt", "md", "csv":
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
        try writeEmptyZip(at: zipPath)
    } else {
        // Rebuilding an existing setup zip must start from a clean archive.
        // `zip -r existing.zip .` updates/adds entries but does not remove files
        // that are absent from the new source directory, which makes deleted
        // suite/support files reappear on the next edit.
        try? fm.removeItem(atPath: zipPath)
        do {
            try repackZipFromDirectory(zipPath: zipPath, sourceDir: tempDir)
        } catch {
            throw WebAssignmentError.internalFailure(reason: "Failed to package setup zip")
        }
    }
    let hasMakefile = storedNameByIndex.values.contains {
        let n = $0.lowercased()
        return n == "makefile" || n == "gnumakefile"
    }
    return RunnerSetupPackage(testSuites: testSuites, hasMakefile: hasMakefile)
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
        // Slice 5 of #461: also extract solution.ipynb's code cells
        // into `solution.py` so personalization expressions can `import
        // solution` and call the canonical helpers (e.g.
        // `solution.caesar_encode(...)`).  An instructor-uploaded
        // `solution.py` support file wins (writeSolutionPyIfNeeded
        // checks for existence first).
        let solutionData = extractZipEntry(zipPath: zipPath, entryName: "solution.ipynb")

        // Preserve a solution-save-generated `solution.py` across the wipe.
        // It is written by the solution-save path (enqueueRunnerValidationSubmission)
        // and lives ONLY in the shared dir — never in the zip — so removing the
        // dir would otherwise drop it until the next solution save, breaking
        // `import solution` in expressions on the next edit. Skip preserving when
        // the zip itself carries the solution: `solution.ipynb` regenerates
        // `solution.py` below, and an instructor-uploaded `solution.py` support
        // file is in `supportNames` and re-copied — either way the zip stays
        // authoritative.
        let solutionPyPath = sharedDir + "solution.py"
        let zipCarriesSolution = solutionData != nil || allEntries.contains("solution.py")
        let preservedSolutionPy: String?
        if !zipCarriesSolution && fm.fileExists(atPath: solutionPyPath) {
            preservedSolutionPy = try? String(contentsOfFile: solutionPyPath, encoding: .utf8)
        } else {
            preservedSolutionPy = nil
        }

        // Always remove the stale shared dir before re-extracting so a support
        // file removed on edit doesn't linger (and so student symlinks to it
        // become visibly broken rather than silently stale).
        if fm.fileExists(atPath: sharedDir) {
            try fm.removeItem(atPath: sharedDir)
        }

        // Skip the dir creation when nothing's going to land in it.
        guard !supportNames.isEmpty || solutionData != nil || preservedSolutionPy != nil else { return }
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
        if let solutionData {
            SolutionNotebookExtractor.writeSolutionPyIfNeeded(
                notebookData: solutionData,
                sharedDirectory: sharedDir
            )
        } else if let preservedSolutionPy {
            // Restore the server-side-only solution.py the wipe removed.
            try preservedSolutionPy.write(toFile: solutionPyPath, atomically: true, encoding: .utf8)
        }
    } catch {
        // Non-fatal: support files are a convenience; log and continue.  A
        // label-constructed Logger routes through the bootstrapped logging
        // system, so this lands with the app's structured logs instead of
        // bypassing them via print (#1127).
        Logger(label: "codes.vapor.application")
            .warning("Failed to extract support files for \(setupID): \(error)")
    }
}
