// Core/NotebookCellSources.swift
//
// Minimal helpers shared by every Jupyter-notebook cell walker in the
// codebase.  Each consumer (Worker's `NotebookExtractor`, Server's
// `SolutionNotebookExtractor`, the kernel-language detector inside
// `extractNotebooksToCode`) layers its own post-processing on top —
// IPython-magic stripping, `if __name__ == "__main__":` wrapping,
// comment headers, etc.  Lifting only the parsing + cell iteration
// preserves each side's intent while removing the shape duplication
// (notebook JSON parsing, cell-type filter, `source`-field
// string-or-array handling).
//
// Lives in `Core` (v0.4.181+).  All functions are best-effort: they
// return `nil` / `[]` on malformed input rather than throwing, since
// every existing caller already wraps their parse step in `try?`.

import Foundation

public enum NotebookCellSources {

    /// Parses notebook JSON bytes and returns the `cells` array as an
    /// untyped sequence of dictionaries.  Returns `nil` if the input
    /// isn't valid notebook-shaped JSON.
    public static func cells(from notebookData: Data) -> [[String: Any]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: notebookData),
            let nb = obj as? [String: Any],
            let cells = nb["cells"] as? [[String: Any]]
        else { return nil }
        return cells
    }

    /// Reads a cell's `source` field, tolerating either form nbformat
    /// permits (a single string, or an array of strings to be joined).
    /// Returns an empty string for missing / wrong-type fields.
    public static func cellSource(_ cell: [String: Any]) -> String {
        if let s = cell["source"] as? String { return s }
        if let arr = cell["source"] as? [String] { return arr.joined() }
        return ""
    }

    /// Returns the trimmed `source` of every `code` cell whose source
    /// is non-empty.  Skips markdown, raw, and empty cells.  Suitable
    /// for the simple "concat code cells" path; callers that need the
    /// cell index for "# --- cell N ---" comments should iterate
    /// `cells(from:)` directly.
    public static func codeCellSources(_ cells: [[String: Any]]) -> [String] {
        cells.compactMap { cell -> String? in
            guard cell["cell_type"] as? String == "code" else { return nil }
            let trimmed = cellSource(cell).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
