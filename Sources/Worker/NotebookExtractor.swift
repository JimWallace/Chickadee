import Core
import Foundation
import RunnerCore

struct NotebookExtraction {
    let source: String
    let introspectableSource: String
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
            notebook["cells"] is [[String: Any]] || notebook["cells"] is [Any]
        else {
            return false
        }
        return true
    }

    func extractPythonSource(from notebook: [String: Any], filename: String) throws -> NotebookExtraction {
        guard let cells = notebook["cells"] as? [[String: Any]] else {
            throw SubmissionNormalizationError.invalidPythonSubmission(filename)
        }

        // Delegate to the shared, dependency-free core so the native worker and
        // the (wasm) browser runner extract notebooks identically.
        let inputCells = cells.map { cell in
            NotebookCell(
                cellType: (cell["cell_type"] as? String) ?? "",
                source: NotebookCellSources.cellSource(cell)
            )
        }
        let extracted = extractPython(cells: inputCells, filename: filename)

        guard extracted.codeCellCount > 0 else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }

        return NotebookExtraction(
            source: extracted.executableModule,
            introspectableSource: extracted.introspectableSource,
            codeCellCount: extracted.codeCellCount
        )
    }

    // The per-cell transforms now live in RunnerCore (the single, wasm-ready
    // source of truth shared with the browser runner). These thin wrappers are
    // kept so existing call sites and tests stay unchanged — they must qualify
    // the core functions to avoid recursing into themselves.

    func sanitizeCellForModule(_ source: String) -> String {
        RunnerCore.sanitizeCellForModule(source)
    }

    func wrapCellForResilientLoad(_ body: String, label: String) -> String {
        RunnerCore.wrapCellForResilientLoad(body, label: label)
    }

    func pythonStringLiteral(_ s: String) -> String {
        RunnerCore.pythonStringLiteral(s)
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
///
/// - Parameter forcedLanguage: when non-nil, every notebook is extracted to
///   that language regardless of its own kernelspec. The worker passes `.r` for
///   a pure-R suite (`manifestTargetsRSubmission`) so a submission whose
///   kernelspec was rewritten by the in-browser editor still extracts to `.R`.
///   Nil keeps the per-notebook kernelspec detection.
func extractNotebooksToCode(in directory: URL, forcedLanguage: AssignmentLanguage? = nil) throws {
    let items =
        (try? FileManager.default.contentsOfDirectory(
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
            let data = try? Data(contentsOf: item),
            let notebook = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells = notebook["cells"] as? [[String: Any]]
        else { continue }

        // A caller-forced language wins over the notebook's own kernelspec;
        // otherwise sniff it with the shared detector.
        let language =
            forcedLanguage ?? (AssignmentLanguage.isRNotebook(notebook) ? .r : .python)

        // Deliberately not `generatedScriptExtension`: that property is scoped to
        // scripts Chickadee *generates* (pattern cases, notebook checks) where the
        // filename feeds `spec_hash`. Extraction output is a different concern and
        // must not be coupled to it.
        let ext: String
        switch language {
        case .python: ext = "py"
        case .r: ext = "R"
        }
        let stem = item.deletingPathExtension().lastPathComponent
        let outURL = directory.appendingPathComponent("\(stem).\(ext)")

        let output: String
        switch language {
        case .r:
            // Flattening concatenates cells, which loses the boundaries a
            // source-level check (`.cellContains`) needs.  Python keeps them
            // because `wrapCellForResilientLoad` labels each cell; R gets the
            // same information from inert marker comments, which
            // `chickadee_student_cells()` splits on.  The assembly lives in
            // RunnerCore (`extractR`) — the same implementation the browser
            // runner calls via wasm, so the two extractors cannot drift.
            let inputCells = cells.map { cell in
                NotebookCell(
                    cellType: (cell["cell_type"] as? String) ?? "",
                    source: NotebookCellSources.cellSource(cell)
                )
            }
            output = extractR(cells: inputCells, filename: item.lastPathComponent).source
        case .python:
            var assembled = "# Generated from \(item.lastPathComponent)\n\n"
            let extractor = NotebookExtractor()
            for (index, cell) in cells.enumerated() {
                guard cell["cell_type"] as? String == "code" else { continue }
                var src = NotebookCellSources.cellSource(cell)
                while src.last?.isWhitespace == true { src.removeLast() }
                guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let cellSource = extractor.sanitizeCellForModule(src)
                guard !cellSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                assembled +=
                    extractor.wrapCellForResilientLoad(cellSource, label: "cell \(index + 1)") + "\n\n"
            }
            output = assembled
        }

        try output.write(to: outURL, atomically: true, encoding: .utf8)
    }
}
