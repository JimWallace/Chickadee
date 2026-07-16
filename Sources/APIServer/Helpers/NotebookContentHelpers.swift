// APIServer/Helpers/NotebookContentHelpers.swift
//
// Pure notebook-JSON and zip-inspection helpers (Data → Data / Data → Bool),
// used across the route layer, services, and the MCP tools: hidden-tier cell
// filtering, student/instructor notebook merging, JupyterLite normalization,
// notebook resolution for a test setup, and setup-zip notebook probes.
// Moved out of TestSetupRoutes.swift in #1119 — they are content utilities,
// not routing.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Notebook cell filtering / merging helpers (free functions)

/// Tiers that students cannot see in the notebook or in downloads.
let hiddenTiersForStudents: Set<String> = ["secret", "release"]

// JupyterLite kernel identifiers used when normalizing notebook metadata.
let jupyterLitePythonKernelName = "python"
let jupyterLitePythonKernelDisplayName = "Python (Pyodide)"
let jupyterLiteRKernelName = "webr"
let jupyterLiteRKernelDisplayName = "R (WebR)"

/// Extracts the joined source string for a notebook cell dictionary.
func cellSource(_ cell: [String: Any]) -> String? {
    if let arr = cell["source"] as? [String] { return arr.joined() }
    if let str = cell["source"] as? String { return str }
    return nil
}

/// Returns true when the cell's first non-empty line is a `# TEST:` comment
/// whose `tier=` value is in `hiddenTiers`.
func isHiddenTestCell(_ cell: [String: Any], hiddenTiers: Set<String>) -> Bool {
    guard let source = cellSource(cell) else { return false }
    let firstLine =
        source
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
    guard firstLine.range(of: #"^#\s*TEST:"#, options: .regularExpression) != nil
    else { return false }
    for token in firstLine.split(separator: " ") {
        let kv = token.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == "tier" {
            return hiddenTiers.contains(String(kv[1]))
        }
    }
    return false  // no explicit tier= found → default "public" → not hidden
}

/// Returns true when the cell's first non-empty line is ANY `# TEST:` comment,
/// regardless of tier. Used to separate solution cells from test cells during merge.
func isTestCell(_ cell: [String: Any]) -> Bool {
    guard let source = cellSource(cell) else { return false }
    let firstLine =
        source
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
    return firstLine.range(of: #"^#\s*TEST:"#, options: .regularExpression) != nil
}

/// Returns a copy of `data` (notebook JSON) with cells matching `hiddenTiers` removed.
/// Returns the original data unchanged if parsing fails.
func filterNotebook(_ data: Data, hiddenTiers: Set<String>) -> Data {
    guard var nb = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let cells = nb["cells"] as? [[String: Any]]
    else { return data }
    nb["cells"] = cells.filter { !isHiddenTestCell($0, hiddenTiers: hiddenTiers) }
    return (try? JSONSerialization.data(withJSONObject: nb)) ?? data
}

/// Merges a student's notebook with the instructor's canonical notebook.
///
/// Result cell list: student's non-test cells + all of the instructor's test cells.
///
/// This ensures the worker sees the student's solution code alongside all
/// authoritative test cells, including those stripped from the student download.
///
/// Returns `studentData` unchanged if either notebook fails to parse.
func mergeNotebook(student studentData: Data, instructor instructorData: Data) -> Data {
    guard var studentNB = (try? JSONSerialization.jsonObject(with: studentData)) as? [String: Any],
        let instructorNB = (try? JSONSerialization.jsonObject(with: instructorData)) as? [String: Any],
        let studentCells = studentNB["cells"] as? [[String: Any]],
        let instructorCells = instructorNB["cells"] as? [[String: Any]]
    else { return studentData }

    let solutionCells = studentCells.filter { !isTestCell($0) }
    let testCells = instructorCells.filter { isTestCell($0) }

    studentNB["cells"] = solutionCells + testCells
    return (try? JSONSerialization.data(withJSONObject: studentNB)) ?? studentData
}

/// Normalizes notebook metadata so JupyterLite can attach the right browser kernel.
///
/// - Python notebooks (`python`/`python3` or missing kernelspec) →
///   kernelspec.name = "python", display_name = "Python (Pyodide)".
/// - R notebooks (`ir`, `r`) →
///   kernelspec.name = "webr", display_name = "R (WebR)".
/// - Any other explicit kernelspec → returned unchanged.
/// - Returns original data unchanged if JSON parsing fails.
func normalizeNotebookForJupyterLite(_ data: Data) -> Data {
    guard var notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return data }

    var metadata = notebook["metadata"] as? [String: Any] ?? [:]
    let existingKernelSpec = metadata["kernelspec"] as? [String: Any]
    let existingName = (existingKernelSpec?["name"] as? String)?.lowercased()

    var kernelSpec = existingKernelSpec ?? [:]
    var languageInfo = metadata["language_info"] as? [String: Any] ?? [:]

    if let name = existingName, name == "ir" || name == "r" {
        // R notebook (IRkernel) → normalize to the JupyterLite webR kernel.
        kernelSpec["name"] = jupyterLiteRKernelName
        kernelSpec["display_name"] = jupyterLiteRKernelDisplayName
        metadata["kernelspec"] = kernelSpec
        if (languageInfo["name"] as? String).map({ $0.isEmpty }) != false {
            languageInfo["name"] = "r"
        }
        metadata["language_info"] = languageInfo
    } else if let name = existingName, !name.isEmpty,
        name != "python", name != "python3"
    {
        // Unknown non-Python, non-R kernel → leave unchanged.
        return data
    } else {
        // Python kernel (or missing kernelspec) → normalize to Python (Pyodide).
        kernelSpec["name"] = jupyterLitePythonKernelName
        kernelSpec["display_name"] = jupyterLitePythonKernelDisplayName
        metadata["kernelspec"] = kernelSpec
        if (languageInfo["name"] as? String)?.isEmpty != false {
            languageInfo["name"] = "python"
        }
        metadata["language_info"] = languageInfo
    }

    notebook["metadata"] = metadata
    return (try? JSONSerialization.data(withJSONObject: notebook)) ?? data
}

/// Loads the notebook data for a test setup.
/// Prefers the flat `.ipynb` file (Phase 8 editable path); falls back to zip extraction.
///
/// - Throws: `NotebookLookupError.notFound` when neither a flat file nor a zip
///   entry is available. Callers can catch this specific type; Vapor's error
///   middleware maps it to HTTP 404 automatically.
/// A `Sendable` snapshot of the test-setup fields needed to resolve a notebook.
/// Lets the (blocking) read run on the NIO thread pool without capturing the
/// non-`Sendable` `APITestSetup` Fluent model in a `@Sendable` closure.
struct NotebookSourceRef: Sendable {
    let notebookPath: String?
    let zipPath: String
    let starterNotebook: String?
    let setupID: String?

    init(_ setup: APITestSetup) {
        self.notebookPath = setup.notebookPath
        self.zipPath = setup.zipPath
        self.starterNotebook = setup.decodedManifest()?.starterNotebook
        self.setupID = setup.id
    }

    /// Memberwise variant for callers (and tests) that don't hold a Fluent
    /// model — e.g. the NotebookBytesCache tests building sources over
    /// temp files (#1171).
    init(notebookPath: String?, zipPath: String, starterNotebook: String?, setupID: String?) {
        self.notebookPath = notebookPath
        self.zipPath = zipPath
        self.starterNotebook = starterNotebook
        self.setupID = setupID
    }
}

func notebookData(for setup: APITestSetup) throws(NotebookLookupError) -> Data {
    try notebookData(from: NotebookSourceRef(setup))
}

/// Primitive-driven variant of `notebookData(for:)`, safe to call from a
/// `@Sendable` thread-pool closure. Behaviour is identical to the model-based
/// overload.
func notebookData(from source: NotebookSourceRef) throws(NotebookLookupError) -> Data {
    if let path = source.notebookPath,
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        !data.isEmpty
    {
        return normalizeNotebookForJupyterLite(data)
    }

    let entries = listZipEntries(zipPath: source.zipPath)
    let preferredEntryNames = notebookCandidateEntryNames(
        starterNotebook: source.starterNotebook, entries: entries)
    for entryName in preferredEntryNames {
        guard let data = extractZipEntry(zipPath: source.zipPath, entryName: entryName),
            !data.isEmpty
        else { continue }
        return normalizeNotebookForJupyterLite(data)
    }

    throw NotebookLookupError.notFound(setupID: source.setupID ?? "unknown")
}

private func notebookCandidateEntryNames(starterNotebook: String?, entries: [String]) -> [String] {
    let manifestStarterName = starterNotebook?.trimmingCharacters(in: .whitespacesAndNewlines)

    var candidates: [String] = []
    var seen: Set<String> = []

    func appendCandidate(_ entry: String?) {
        guard let entry, !entry.isEmpty, !seen.contains(entry) else { return }
        seen.insert(entry)
        candidates.append(entry)
    }

    func appendMatchingEntries(named filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        let exactMatches = entries.filter { $0 == filename }
        if !exactMatches.isEmpty {
            exactMatches.forEach(appendCandidate)
            return
        }
        entries
            .filter { ($0 as NSString).lastPathComponent == filename }
            .forEach(appendCandidate)
    }

    appendMatchingEntries(named: manifestStarterName)
    appendMatchingEntries(named: "assignment.ipynb")
    entries
        .filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "ipynb" }
        .forEach(appendCandidate)

    return candidates
}

// MARK: - Zip inspection helpers

/// Returns true if the zip archive contains at least one `.ipynb` file.
/// Uses `unzip -l` (list mode) so no files are extracted.
func zipContainsNotebook(_ zipData: Data) -> Bool {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("chickadee_zip_check_\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: tmp) }

    guard (try? zipData.write(to: tmp)) != nil else { return false }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-l", tmp.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    guard (try? proc.run()) != nil else { return false }
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    return output.contains(".ipynb")
}

/// Extracts `assignment.ipynb` from the zip at `zipPath` and returns its Data,
/// or nil if the file is not present or unzip fails.
func extractNotebookFromZip(zipPath: String) -> Data? {
    let entries = listZipEntries(zipPath: zipPath)
    let candidate =
        entries.first {
            ($0 as NSString).lastPathComponent == "assignment.ipynb"
        }
        ?? entries.first {
            URL(fileURLWithPath: $0).pathExtension.lowercased() == "ipynb"
        }
    guard let candidate else { return nil }
    return extractZipEntry(zipPath: zipPath, entryName: candidate)
}
