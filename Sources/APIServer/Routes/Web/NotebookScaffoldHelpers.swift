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

/// Runs a section-aware scan over `notebookData` and, if the test setup looks
/// "fresh" (no existing sections, no existing test scripts), declares the
/// notebook's `## ` headers as suite sections.
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

    // Language-aware: the generated "exists" scripts are PYTHON, so they must
    // not be written for a language whose functions this scanner cannot read.
    // The SECTIONS are a different question — a `## ` header is markdown, not
    // code — and the scan now answers the two separately.
    let scanLanguage =
        setup.decodedManifest().flatMap { AssignmentLanguage.resolve(for: setup, manifest: $0) }
    let scan = scanNotebookForSectionsAndFunctions(notebookData, language: scanLanguage)
    // Sections are worth scaffolding on their own. This used to bail whenever
    // no functions were found, which denied section scaffolding to every
    // language the scanner cannot read — collateral from a limitation that
    // applies only to function extraction — and to a Python solution that
    // organises its work in headers without defining top-level functions.
    guard !scan.functions.isEmpty || !scan.sectionNames.isEmpty else { return (0, 0) }

    // 1. Assign a stable UUID per section (server-generated; clients
    //    get it back via GET /suite).
    var sectionIDByName: [String: String] = [:]
    var sectionDicts: [[String: Any]] = []
    for name in scan.sectionNames {
        let id = UUID().uuidString
        sectionIDByName[name] = id
        sectionDicts.append(["id": id, "name": name])
    }

    // 2. NO PER-FUNCTION SCRIPTS. This used to write one
    //    `publictest_exists_<fn>.py` per detected function, from the `exists`
    //    template — which was removed along with the seven other Python
    //    templates a pattern-family kind already covers. The existence guard it
    //    generated is emitted automatically by every family, in all six
    //    languages, so the scaffold was seeding a Python script to do a job the
    //    first-class construct does better and everywhere.
    //
    //    Sections are still scaffolded, which is the part of this flow that was
    //    always language-neutral and always useful.
    let newSuites: [[String: Any]] = []

    // 4. Rewrite the manifest with sections + testSuites populated.
    //    Preserve every other field the manifest already had (gradingMode,
    //    timeLimitSeconds, etc.).
    dict["sections"] = sectionDicts
    dict["testSuites"] = newSuites
    let newData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    guard let newManifest = String(data: newData, encoding: .utf8) else { return (0, 0) }
    setup.manifest = newManifest
    try await setup.save(on: db)

    return (scan.sectionNames.count, 0)
}

/// Refusal shown when a notebook is scaffolded for a language that has none.
///
/// Phrased for an instructor looking at a button that should not have been
/// offered — so it says what to do instead, not just what went wrong.
let uploadOnlyNotebookScaffoldMessage =
    "This assignment's language has no in-browser notebook editor, so there is no notebook to "
    + "create. Students submit files, and the reference solution is uploaded as a source file "
    + "rather than authored as a notebook."

/// A blank starter notebook in `language`.
///
/// THE KERNELSPEC IS DERIVED. This hardcoded `xpython` / `Python
/// (xeus-python)` / `"language": "python"` for every language, and is called
/// from four sites that had no language to pass. So an instructor who selected
/// R and clicked "Create assignment notebook" got a Python notebook: the
/// assignment still resolved R, because a recorded manifest language outranks
/// the kernelspec, and the result was generated `.R` tests beside an editor
/// booting `xpython`. On a draft with no recorded language the kernelspec is
/// the ONLY signal, and `normalizeNotebookForJupyterLite` maps a missing one to
/// Python — so the wrong answer was also a sticky one.
///
/// nil means the assignment declares no language (a plain `.sh` suite), which
/// keeps Python: the previous behaviour, and the only defensible default when
/// nothing names a language.
///
/// Returns nil for an upload-only language. C++ and Racket have no notebook
/// workflow at all, and scaffolding one would promise students an editor that
/// cannot serve them — the same refusal `submissionMode` already enforces,
/// moved to the point where the file would be written.
func defaultNotebookData(title: String, language: AssignmentLanguage? = nil) -> Data? {
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let kernel: (name: String, displayName: String, languageName: String)
    switch (language ?? .python).editorSupport {
    case .notebookKernel(_, let kernelName, let kernelDisplayName, _, _):
        kernel = (kernelName, kernelDisplayName, (language ?? .python).rawValue)
    case .uploadOnly:
        return nil
    }
    // The starter cell's comment is the language's own — `#` was written into
    // every notebook, which is a comment in Python, R and Octave and not in
    // Lua. Same fact, same owner as the raw-script banner.
    let starterComment = (language ?? .python).lineCommentPrefix
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
              "source": ["\(starterComment) Student solution starts here\\n"]
            }
          ],
          "metadata": {
            "kernelspec": {
              "display_name": "\(kernel.displayName)",
              "language": "\(kernel.languageName)",
              "name": "\(kernel.name)"
            },
            "language_info": {
              "name": "\(kernel.languageName)"
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
