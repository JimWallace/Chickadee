import Foundation

struct NotebookExtraction {
    let source: String
    let codeCellCount: Int
}

struct NotebookExtractor {
    func notebookJSONObject(from data: Data, filename: String) throws -> [String: Any] {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        guard let object = rawObject as? [String: Any] else {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        return object
    }

    func isNotebookJSONObject(_ notebook: [String: Any]) -> Bool {
        guard notebook["metadata"] != nil,
              notebook["nbformat"] != nil,
              notebook["cells"] is [[String: Any]] || notebook["cells"] is [Any] else {
            return false
        }
        return true
    }

    func extractPythonSource(from notebook: [String: Any], filename: String) throws -> NotebookExtraction {
        guard let cells = notebook["cells"] as? [[String: Any]] else {
            throw SubmissionNormalizationError.invalidPythonSubmission(filename)
        }

        var parts: [String] = []
        var codeCellCount = 0

        for (index, cell) in cells.enumerated() {
            guard cell["cell_type"] as? String == "code" else { continue }

            let rawSource: String
            if let sourceLines = cell["source"] as? [String] {
                rawSource = sourceLines.joined()
            } else if let sourceString = cell["source"] as? String {
                rawSource = sourceString
            } else {
                continue
            }

            let trimmedSource = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty else { continue }
            codeCellCount += 1
            parts.append("# --- cell \(index + 1) ---\n\(trimmedSource)")
        }

        guard !parts.isEmpty else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }

        return NotebookExtraction(
            source: "# Generated from \(filename)\n\n" + parts.joined(separator: "\n\n") + "\n",
            codeCellCount: codeCellCount
        )
    }
}

// MARK: - Notebook-to-code extraction for test setup directories

/// Extract code cells from all .ipynb notebooks in `directory` into .py or .R source files.
///
/// This replaces the former runner-support/Makefile prep step with a pure-Swift
/// implementation. The .ipynb format is plain JSON — no `make`, Python, or external
/// tools are required. Kernel language detection mirrors the logic in
/// TestSetupRoutes.normalizeNotebookForJupyterLite() and browser-runner.js.
///
/// Module-level (not private) so WorkerTests can exercise it directly.
func extractNotebooksToCode(in directory: URL) throws {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []

    for item in items where item.pathExtension.lowercased() == "ipynb" {
        // Every .ipynb in the directory is extracted to .py (or .R).  The
        // starter template notebook is already removed by process() before
        // this function runs (driven by manifest.starterNotebook), so the
        // only notebooks remaining are the student/canonical submission and
        // any instructor-provided helper notebooks that should be converted.
        guard
            let data     = try? Data(contentsOf: item),
            let notebook = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells    = notebook["cells"] as? [[String: Any]]
        else { continue }

        // Detect kernel language: ir/r/webr → R, everything else → Python.
        let language: String = {
            if let meta = notebook["metadata"] as? [String: Any] {
                if let ks = meta["kernelspec"] as? [String: Any],
                   let name = (ks["name"] as? String)?.lowercased() {
                    if name == "ir" || name == "r" || name == "webr" { return "r" }
                }
                if let li = meta["language_info"] as? [String: Any],
                   (li["name"] as? String)?.lowercased() == "r" { return "r" }
            }
            return "python"
        }()

        let ext    = language == "r" ? "R" : "py"
        let stem   = item.deletingPathExtension().lastPathComponent
        let outURL = directory.appendingPathComponent("\(stem).\(ext)")

        var output = "# Generated from \(item.lastPathComponent)\n\n"
        for cell in cells {
            guard cell["cell_type"] as? String == "code" else { continue }
            let raw: String
            if let arr = cell["source"] as? [String] {
                raw = arr.joined()
            } else if let str = cell["source"] as? String {
                raw = str
            } else { continue }

            // Mirror Python's rstrip(): strip trailing whitespace/newlines.
            var src = raw
            while src.last?.isWhitespace == true { src.removeLast() }
            guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            output += src + "\n\n"
        }

        try output.write(to: outURL, atomically: true, encoding: .utf8)
    }
}
