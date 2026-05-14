// APIServer/Routes/Web/NotebookScaffoldHelpers.swift
//
// Notebook filename normalization, default-notebook construction, the
// "auto-scaffold from solution notebook" flow (v0.4.100+), and cleanup
// of materialized JupyterLite copies.  Extracted from
// AssignmentHelpers.swift (issue #442) — no behaviour changes.

import Core
import Fluent
import Foundation
import Vapor

func minimalEmptyNotebookData() -> Data {
    Data(#"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#.utf8)
}

func notebookFilenameForStorage(uploadedName: String?, fallback: String) -> String {
    var fileName = uploadedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if fileName.isEmpty {
        fileName = fallback
    }
    fileName = URL(fileURLWithPath: fileName).lastPathComponent
    fileName =
        fileName
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if fileName.isEmpty {
        fileName = fallback
    }
    if !fileName.lowercased().hasSuffix(".ipynb") {
        fileName += ".ipynb"
    }
    return fileName
}

func submissionFilenameForStorage(uploadedName: String?, fallback: String) -> String {
    var fileName = uploadedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if fileName.isEmpty {
        fileName = fallback
    }
    fileName = URL(fileURLWithPath: fileName).lastPathComponent
    fileName =
        fileName
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if fileName.isEmpty {
        fileName = fallback
    }
    return fileName
}

/// Runs a section-aware scan over `notebookData` and, if the test setup
/// looks "fresh" (no existing sections, no existing test scripts), writes
/// one `publictest_exists_<fn>.py` scaffold per detected function into
/// the zip and updates the manifest to declare the sections + entries.
///
/// Silently no-ops if the setup already has sections or test entries —
/// instructors who've manually arranged things shouldn't get clobbered
/// by a re-upload of the solution notebook.  One-shot behaviour only.
/// v0.4.100+.
@discardableResult
func autoScaffoldFromSolutionNotebook(
    setup: APITestSetup,
    notebookData: Data,
    zipPath: String,
    on db: Database
) async throws -> (sections: Int, functions: Int) {
    // Parse the existing manifest so we know whether to scaffold.
    guard let data = setup.manifest.data(using: .utf8),
        var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        return (0, 0)
    }
    let existingSections = (dict["sections"] as? [[String: Any]]) ?? []
    let existingSuites = (dict["testSuites"] as? [[String: Any]]) ?? []
    guard existingSections.isEmpty && existingSuites.isEmpty else {
        // Manifest already has structure — the instructor is on a
        // subsequent upload or has manually curated things.  Leave it
        // alone per the v0.4.100 scope ("create flow only, one-shot").
        return (0, 0)
    }

    let scan = scanNotebookForSectionsAndFunctions(notebookData)
    // Nothing useful to scaffold if no functions were found.  Still add
    // the sections (they're cheap) so the instructor can drop their own
    // scripts in.  But with zero functions there's also little value —
    // bail out to keep the manifest minimal.
    guard !scan.functions.isEmpty else { return (0, 0) }

    // 1. Assign a stable UUID per section (server-generated; clients
    //    get it back via GET /suite).
    var sectionIDByName: [String: String] = [:]
    var sectionDicts: [[String: Any]] = []
    for name in scan.sectionNames {
        let id = UUID().uuidString
        sectionIDByName[name] = id
        sectionDicts.append(["id": id, "name": name])
    }

    // 2. Generate one "exists" test script per detected function.
    //    Skip shadowed redefinitions — Python's last-def-wins semantics
    //    means the earlier function isn't reachable at test time.
    var writes: [String: String] = [:]
    var newSuites: [[String: Any]] = []
    for entry in scan.functions where !entry.info.isShadowed {
        let fn = entry.info.name
        let filename = "publictest_exists_\(fn).py"
        guard writes[filename] == nil else { continue }  // dedup by filename
        writes[filename] = pythonTestScript(type: .exists, functionName: fn)
        var testDict: [String: Any] = [
            "tier": "public",
            "script": filename,
            "name": "\(fn) exists",
        ]
        if let sectionName = entry.sectionName, let sid = sectionIDByName[sectionName] {
            testDict["sectionID"] = sid
        }
        newSuites.append(testDict)
    }
    guard !writes.isEmpty else { return (scan.sectionNames.count, 0) }

    // 3. Write the scaffold files into the zip (idempotent — if the file
    //    somehow already exists, the same content overwrites).
    try applyScriptChangesToZip(zipPath: zipPath, writes: writes, deletions: [])

    // 4. Rewrite the manifest with sections + testSuites populated.
    //    Preserve every other field the manifest already had (gradingMode,
    //    timeLimitSeconds, etc.).
    dict["sections"] = sectionDicts
    dict["testSuites"] = newSuites
    let newData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    guard let newManifest = String(data: newData, encoding: .utf8) else { return (0, 0) }
    setup.manifest = newManifest
    try await setup.save(on: db)

    return (scan.sectionNames.count, writes.count)
}

func defaultNotebookData(title: String) -> Data {
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let json = """
        {
          "cells": [
            {
              "cell_type": "markdown",
              "metadata": {},
              "source": ["# \(safeTitle)\\n", "\\n", "Write your assignment instructions here.\\n"]
            },
            {
              "cell_type": "code",
              "execution_count": null,
              "metadata": {},
              "outputs": [],
              "source": ["# Student solution starts here\\n"]
            }
          ],
          "metadata": {
            "kernelspec": {
              "display_name": "Python (Pyodide)",
              "language": "python",
              "name": "python"
            },
            "language_info": {
              "name": "python"
            }
          },
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
    return Data(json.utf8)
}

func removeMaterializedNotebookFiles(req: Request, setupID: String) {
    let roots = [
        req.application.directory.publicDirectory + "files/",
        req.application.directory.publicDirectory + "jupyterlite/files/",
        req.application.directory.publicDirectory + "jupyterlite/lab/files/",
        req.application.directory.publicDirectory + "jupyterlite/notebooks/files/",
    ]
    for root in roots {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for name in entries where name.hasPrefix(setupID) && name.hasSuffix(".ipynb") {
            try? FileManager.default.removeItem(atPath: root + name)
        }
    }
}
