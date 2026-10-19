// Core/NotebookCellSources.swift
//
// Minimal helpers for the Jupyter-notebook cell walkers that change cells or
// that must reject invalid JSON. A read-only walker uses `NotebookCellView`
// instead, which is typed and does not decode the outputs.
//
// Each consumer (Worker's `NotebookExtractor`, the kernel-language detector
// inside `extractNotebooksToCode`) layers its own post-processing on top —
// IPython-magic stripping, `if __name__ == "__main__":` wrapping,
// comment headers, etc.  Lifting only the parsing + cell iteration
// preserves each side's intent while removing the shape duplication
// (notebook JSON parsing, cell-type filter, `source`-field
// string-or-array handling).
//
// Lives in `Core` (v0.4.181+).  All functions are best-effort: they
// return `nil` / `[]` on malformed input rather than throwing, since
// every existing caller already wraps their parse step in `try?`.

public import Foundation

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
    ///
    /// The `[String: JSONValue]` overload below states the same rule. Keep the
    /// two the same until this one has no caller.
    public static func cellSource(_ cell: [String: Any]) -> String {
        if let s = cell["source"] as? String { return s }
        if let arr = cell["source"] as? [String] { return arr.joined() }
        return ""
    }

    /// The same read over a cell parsed as `JSONValue`, with the same rule as
    /// the `[String: Any]` overload above: an array form counts only when
    /// every element is a string, the same as `as? [String]`.
    public static func cellSource(_ cell: [String: JSONValue]) -> String {
        switch cell["source"] {
        case .string(let source):
            return source
        case .array(let parts):
            let strings = parts.compactMap(\.stringValue)
            return strings.count == parts.count ? strings.joined() : ""
        default:
            return ""
        }
    }
}
