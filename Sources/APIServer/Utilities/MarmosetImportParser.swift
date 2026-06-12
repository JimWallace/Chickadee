// APIServer/Utilities/MarmosetImportParser.swift
//
// Utilities for parsing Marmoset export zips and converting them to
// Chickadee test setups.
//
// Marmoset exports a zip containing per-project file groups:
//   <n>-test-setup.zip          — test scripts, Makefile, support files, test.properties
//   <n>-canonical.zip           — canonical reference solution
//   <n>-project-starter-files.zip  — student starter template (may include .ipynb)
//   <n>.project.out             — Java-serialised project metadata (title, IDs)
//
// Only `test.class.*` fields from test.properties are read; all `build.*`
// fields are ignored — Chickadee always uses its own Makefile handling.

import Core
import Foundation

// MARK: - Parsed Marmoset project

struct MarmosetProject: Sendable {
    let number: Int
    let publicTests: [String]
    let releaseTests: [String]
    let secretTests: [String]
    let hasMakefile: Bool
    let suggestedTitle: String?
}

// MARK: - Entry point

/// Parses the contents of an extracted Marmoset export directory and returns
/// one `MarmosetProject` per project number found.
///
/// `extractedDir` is the directory produced by extracting the outer export zip.
/// Returns the resolved directory (unwrapping a single top-level subdirectory if present)
/// and the parsed projects. The caller should use the returned URL when building paths
/// into the archive (e.g. to locate inner zips).
func parseMarmosetExport(from extractedDir: URL) throws -> (projectsDir: URL, projects: [MarmosetProject]) {
    let fm = FileManager.default
    var entries = try fm.contentsOfDirectory(atPath: extractedDir.path)

    // If the zip extracted into a single subdirectory (common when the archive
    // was created with a top-level folder), descend into it automatically.
    let realEntries = entries.filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
    var searchDir = extractedDir
    if realEntries.count == 1 {
        let candidate = extractedDir.appendingPathComponent(realEntries[0])
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            searchDir = candidate
            entries = (try? fm.contentsOfDirectory(atPath: candidate.path)) ?? []
        }
    }

    // Find project numbers by looking for "<n>-test-setup.zip".
    let projectNumbers: [Int] = entries.compactMap { name -> Int? in
        guard name.hasSuffix("-test-setup.zip") else { return nil }
        let prefix = name.dropLast("-test-setup.zip".count)
        return Int(prefix)
    }.sorted()

    let projects = try projectNumbers.map { n in
        try parseProject(number: n, in: searchDir, entries: entries)
    }
    return (projectsDir: searchDir, projects: projects)
}

// MARK: - Per-project parsing

private func parseProject(number n: Int, in dir: URL, entries: [String]) throws -> MarmosetProject {
    let fm = FileManager.default
    let testSetupZip = dir.appendingPathComponent("\(n)-test-setup.zip").path
    // Marmoset names this file "<n>-project.out" (dash), not "<n>.project.out".
    let projectOutPath = dir.appendingPathComponent("\(n)-project.out").path

    // ── 1. List inner zip contents ─────────────────────────────────────

    let innerEntries: [String]
    do {
        innerEntries = try listZipContents(zipPath: testSetupZip)
    } catch {
        innerEntries = []
    }

    // ── 2. Check for Makefile ──────────────────────────────────────────

    let hasMakefile = innerEntries.contains { entry in
        let name = (entry as NSString).lastPathComponent
        return name == "Makefile" || name == "makefile"
    }

    // ── 3. Extract and parse test.properties ──────────────────────────

    let propsData = try extractFileFromZip(zipPath: testSetupZip, filename: "test.properties")
    let props = propsData.flatMap { parseJavaProperties($0) } ?? [:]

    let publicTests = parseTestClassList(props["test.class.public"] ?? "")
    let releaseTests = parseTestClassList(props["test.class.release"] ?? "")
    let secretTests = parseTestClassList(props["test.class.secret"] ?? "")

    // ── 4. Try to extract title from project.out ───────────────────────

    let suggestedTitle: String?
    if fm.fileExists(atPath: projectOutPath),
        let outData = try? Data(contentsOf: URL(fileURLWithPath: projectOutPath))
    {
        suggestedTitle = extractTitleFromProjectOut(outData)
    } else {
        suggestedTitle = nil
    }

    return MarmosetProject(
        number: n,
        publicTests: publicTests,
        releaseTests: releaseTests,
        secretTests: secretTests,
        hasMakefile: hasMakefile,
        suggestedTitle: suggestedTitle
    )
}

// MARK: - Java Properties parser

/// Parses a Java-style `.properties` file.
///
/// Handles:
/// - `key=value` pairs
/// - `#` and `!` line comments
/// - Backslash line-continuation (trailing `\`)
/// - Leading whitespace trimming on continuation lines
func parseJavaProperties(_ data: Data) -> [String: String] {
    guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }

    var result: [String: String] = [:]
    let lines = raw.components(separatedBy: .newlines)
    var i = 0

    while i < lines.count {
        var line = lines[i]
        i += 1

        // Join continuation lines.
        while line.hasSuffix("\\") {
            line = String(line.dropLast())  // remove trailing backslash
            if i < lines.count {
                let next = lines[i].drop(while: { $0 == " " || $0 == "\t" })
                line += next
                i += 1
            }
        }

        // Strip leading whitespace and skip comments / empty lines.
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }

        // Split on first `=` or `:`.
        if let eqRange = line.range(of: "=") {
            let key = line[..<eqRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let val = line[eqRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                result[key] = val
            }
        } else if let colonRange = line.range(of: ":") {
            let key = line[..<colonRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let val = line[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                result[key] = val
            }
        }
    }

    return result
}

/// Splits a Marmoset `test.class.*` value (comma-separated, may contain
/// whitespace and backslash-continuation artefacts) into individual test names.
func parseTestClassList(_ raw: String) -> [String] {
    raw.components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

// MARK: - project.out title extraction

/// Attempts to extract the assignment title from a Java-serialised `project.out`.
///
/// Java serialisation stores UTF-8 strings preceded by a 2-byte big-endian
/// length. We scan for all such strings and return the first one that looks
/// like an assignment title (3–80 printable ASCII chars, not a number alone).
func extractTitleFromProjectOut(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    var candidates: [String] = []
    var idx = 0

    while idx + 2 < bytes.count {
        let high = bytes[idx]
        let low = bytes[idx + 1]
        let len = Int(high) << 8 | Int(low)

        // Only bother with strings of length 3..80.
        guard len >= 3, len <= 80, idx + 2 + len <= bytes.count else {
            idx += 1
            continue
        }

        let strBytes = bytes[(idx + 2)..<(idx + 2 + len)]
        // Require all bytes to be printable ASCII (0x20–0x7E) or basic Latin.
        let allPrintable = strBytes.allSatisfy { b in
            (b >= 0x20 && b <= 0x7E) || b >= 0xC0
        }
        guard allPrintable,
            let s = String(bytes: strBytes, encoding: .utf8),
            !s.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            idx += 1
            continue
        }

        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // Filter out pure numbers, single-character strings, and Java class names.
        if Double(trimmed) == nil,
            trimmed.count >= 3,
            !trimmed.contains("."),
            !trimmed.contains("/"),
            trimmed.contains(" ") || trimmed.first?.isUppercase == true
        {
            candidates.append(trimmed)
        }
        idx += 1
    }

    // Return the first candidate that looks most like a title (contains a space).
    return candidates.first(where: { $0.contains(" ") }) ?? candidates.first
}

// MARK: - Manifest conversion

/// Produces a Chickadee `TestProperties` manifest JSON string from a parsed
/// `MarmosetProject`.
///
/// - `gradingMode` is always `"worker"` (Marmoset test scripts run server-side).
/// - `requiredFiles` is always `[]` — instructor fills this in after import.
/// - `dependsOn` is always `[]` — Marmoset has no dependency concept.
func convertToChickadeeManifest(project: MarmosetProject) throws -> String {
    var suites: [[String: Any]] = []

    for name in project.publicTests {
        suites.append(["tier": "public", "script": name])
    }
    for name in project.releaseTests {
        suites.append(["tier": "release", "script": name])
    }
    for name in project.secretTests {
        suites.append(["tier": "secret", "script": name])
    }

    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "gradingMode": "worker",
        "requiredFiles": [],
        "testSuites": suites,
        "timeLimitSeconds": 10,
        "makefile": NSNull(),  // Marmoset Makefiles are stripped; runner handles .ipynb→.py natively
        "starterNotebook": "assignment.ipynb",
    ]

    let data = try JSONSerialization.data(withJSONObject: manifest)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Zip helpers (private)

/// Extracts a single named file from a zip archive using `unzip -p`.
/// Returns `nil` if the file is not found.  Runs under the shared zip
/// process lock (see `ZipProcessSerialization.swift`) so it can't race
/// the other zip helpers in the codebase.
private func extractFileFromZip(zipPath: String, filename: String) throws -> Data? {
    guard FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
        throw ZipArchiverError.executableNotFound("/usr/bin/unzip")
    }
    let entryName =
        try listZipContents(zipPath: zipPath).first(where: { entry in
            entry == filename || (entry as NSString).lastPathComponent == filename
        }) ?? filename
    let (status, data): (Int32, Data) = try withZipProcessLock {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", zipPath, entryName]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try runProcessWithEFAULTRetry(proc)
        let captured = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, captured)
    }
    // Exit 11 = file not found in archive; treat as nil.
    guard status == 0 else { return nil }
    return data.isEmpty ? nil : data
}

/// Returns the first `.ipynb` filename found in a zip archive, or `nil`.
func firstNotebookInZip(zipPath: String) throws -> String? {
    let entries = try listZipContents(zipPath: zipPath)
    return entries.first { entry in
        let name = (entry as NSString).lastPathComponent
        return name.hasSuffix(".ipynb") && !name.hasPrefix(".")
    }.map { ($0 as NSString).lastPathComponent }
}

/// Extracts a named file from a zip archive and returns its bytes.
/// The filename is the last path component match (for nested paths).
func extractNotebookFromZip(zipPath: String, filename: String) throws -> Data? {
    return try extractFileFromZip(zipPath: zipPath, filename: filename)
}

/// Extracts the first non-hidden file from a canonical zip.
/// Returns the file data, its extension, and original filename, or `nil` if none found.
func extractSolutionFromCanonicalZip(zipPath: String) throws -> (data: Data, ext: String, originalFilename: String)? {
    let entries = try listZipContents(zipPath: zipPath)
    guard
        let entry = entries.first(where: { e in
            let name = (e as NSString).lastPathComponent
            return !name.hasPrefix(".") && !name.isEmpty
        })
    else { return nil }
    let filename = (entry as NSString).lastPathComponent
    let ext = (filename as NSString).pathExtension.lowercased()
    guard let data = try extractFileFromZip(zipPath: zipPath, filename: filename),
        !data.isEmpty
    else { return nil }
    return (data: data, ext: ext, originalFilename: filename)
}
