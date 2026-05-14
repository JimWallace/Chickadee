// APIServer/Services/SolutionNotebookExtractor.swift
//
// Slice 5 of #461 — walks a solution notebook's code cells and writes
// a flat `solution.py` file that personalization expressions can
// `import`.  Mirrors the Worker's `NotebookExtractor` in spirit but
// scoped to the server-side authoring path (no IPython-magic stripping,
// no `if __name__ == "__main__"` wrapping — we want the function
// definitions and module-level constants exactly as the instructor
// wrote them so expressions can call them).
//
// Lives parallel to `extractSupportFilesToSharedDirectory` in
// `TestSetupZipHelpers.swift`: called after every test-setup save so
// `shared/{setupID}/solution.py` stays in sync with the canonical
// `solution.ipynb` in the test setup zip.  Skipped when the instructor
// uploaded a `solution.py` of their own — explicit beats derived.

import Foundation

enum SolutionNotebookExtractor {

    /// Concatenates the `source` of every `code` cell in the supplied
    /// notebook JSON into a single Python file.  Markdown / raw cells
    /// are skipped.  Returns nil when the input isn't a valid notebook.
    static func extractCodeToPython(notebookData: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: notebookData),
              let nb  = obj as? [String: Any],
              let cells = nb["cells"] as? [[String: Any]]
        else { return nil }

        var lines: [String] = [
            "# Auto-generated from solution.ipynb by Chickadee.",
            "# Used by personalization expressions to import the instructor's",
            "# canonical helpers (e.g. `solution.caesar_encode(...)`).",
            "# Regenerated on every test-setup save; do not edit by hand.",
            ""
        ]

        for cell in cells {
            guard let kind = cell["cell_type"] as? String, kind == "code" else { continue }
            let source = readCellSource(cell)
            // Concatenate cells with a blank line between them so module
            // top-level statements don't accidentally merge into a single
            // line.  Strip trailing whitespace from each cell to keep the
            // output tidy.
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Writes `solution.py` into `sharedDirectory` from
    /// `solutionNotebookData` if and only if:
    /// - the notebook contains at least one non-empty code cell, AND
    /// - `sharedDirectory` doesn't already contain a `solution.py`
    ///   (instructor-uploaded support files take precedence).
    ///
    /// Returns true if a file was written.  Errors are swallowed
    /// (logged in production by the caller); the personalization
    /// evaluator works without solution.py present.
    @discardableResult
    static func writeSolutionPyIfNeeded(
        notebookData: Data,
        sharedDirectory: String
    ) -> Bool {
        let fm = FileManager.default
        let target = (sharedDirectory as NSString).appendingPathComponent("solution.py")

        // Don't overwrite an instructor-uploaded solution.py.
        if fm.fileExists(atPath: target) { return false }

        guard let py = extractCodeToPython(notebookData: notebookData) else { return false }
        // Skip when the notebook had no executable cells — writing an
        // empty `solution.py` would shadow nothing useful.
        let effectiveLines = py
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !effectiveLines.isEmpty else { return false }

        do {
            // Make sure the directory exists; the caller usually creates
            // it via extractSupportFilesToSharedDirectory but defend
            // against an out-of-order call.
            try fm.createDirectory(atPath: sharedDirectory,
                                   withIntermediateDirectories: true)
            try py.write(toFile: target, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    /// nbformat's `source` field is either a string or an array of
    /// strings; tolerate both.
    private static func readCellSource(_ cell: [String: Any]) -> String {
        if let s = cell["source"] as? String { return s }
        if let arr = cell["source"] as? [String] { return arr.joined() }
        return ""
    }
}
