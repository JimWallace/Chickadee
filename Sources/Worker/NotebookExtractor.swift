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

            let cellSource = sanitizeCellForModule(trimmedSource)
            guard !cellSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            codeCellCount += 1
            parts.append("# --- cell \(index + 1) ---\n\(cellSource)")
        }

        guard !parts.isEmpty else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }

        return NotebookExtraction(
            source: "# Generated from \(filename)\n\n" + parts.joined(separator: "\n\n") + "\n",
            codeCellCount: codeCellCount
        )
    }

    // Sanitizes a single notebook code cell for use as a module-level Python
    // source block:
    //
    //   • IPython magic commands (lines beginning with %) and shell pass-through
    //     commands (lines beginning with !) are stripped — they are never valid
    //     Python outside a Jupyter kernel.
    //
    //   • Top-level statements are classified as either *definition* lines
    //     (def, async def, class, import, from, decorator @, or comment #) or
    //     *usage* lines (everything else: calls, assignments, print statements,
    //     assertions, etc.).  Each top-level statement and its indented body
    //     travel together.
    //
    //   • Definition code is emitted at module level so functions and classes
    //     remain importable by the test runner.
    //
    //   • Usage code is wrapped in `if __name__ == "__main__":` so it does not
    //     execute — and cannot raise NameError, crash, or produce side-effects —
    //     when the generated file is imported as a module.
    //
    // Example input cell:
    //
    //   def mailingLabel(record):
    //       ...
    //
    //   print(mailingLabel(patient0))   # student test call
    //
    // Output:
    //
    //   def mailingLabel(record):
    //       ...
    //
    //   if __name__ == "__main__":
    //       print(mailingLabel(patient0))
    //
    func sanitizeCellForModule(_ source: String) -> String {
        // Strip magic/shell lines first.
        let lines = source.components(separatedBy: "\n").filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return !s.hasPrefix("%") && !s.hasPrefix("!")
        }

        // Walk line-by-line, routing each line to the definition or usage bucket.
        // A top-level (non-indented, non-empty) line sets the current block kind;
        // subsequent indented lines (the block body) inherit that kind.
        var defLines:   [String] = []
        var usageLines: [String] = []
        var inUsage = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTopLevel = !line.isEmpty && !(line.first?.isWhitespace ?? true)

            if isTopLevel && !trimmed.isEmpty {
                inUsage = !(trimmed.hasPrefix("def ")      ||
                            trimmed.hasPrefix("async def ") ||
                            trimmed.hasPrefix("class ")    ||
                            trimmed.hasPrefix("import ")   ||
                            trimmed.hasPrefix("from ")     ||
                            trimmed.hasPrefix("@")         ||
                            trimmed.hasPrefix("#"))
            }

            if inUsage {
                usageLines.append(line)
            } else {
                defLines.append(line)
            }
        }

        var parts: [String] = []

        let defBlock = defLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !defBlock.isEmpty {
            parts.append(defBlock)
        }

        let usageBlock = usageLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !usageBlock.isEmpty {
            let indented = usageBlock
                .components(separatedBy: "\n")
                .map { "    " + $0 }
                .joined(separator: "\n")
            parts.append("if __name__ == \"__main__\":\n\(indented)")
        }

        return parts.joined(separator: "\n\n")
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
        let extractor = NotebookExtractor()
        for cell in cells {
            guard cell["cell_type"] as? String == "code" else { continue }
            let raw: String
            if let arr = cell["source"] as? [String] {
                raw = arr.joined()
            } else if let str = cell["source"] as? String {
                raw = str
            } else { continue }

            var src = raw
            while src.last?.isWhitespace == true { src.removeLast() }
            guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if language == "python" {
                let cellSource = extractor.sanitizeCellForModule(src)
                guard !cellSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                output += cellSource + "\n\n"
            } else {
                output += src + "\n\n"
            }
        }

        try output.write(to: outURL, atomically: true, encoding: .utf8)
    }
}
