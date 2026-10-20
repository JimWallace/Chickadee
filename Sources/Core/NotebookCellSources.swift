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

    /// Parses notebook JSON bytes and returns the `cells` array. Returns `nil`
    /// if the input is not valid JSON, is not an object, or its `cells` is not
    /// an array of objects. Every value is decoded, so invalid JSON anywhere
    /// gives nil.
    public static func cells(from notebookData: Data) -> [[String: JSONValue]]? {
        JSONValue.object(from: notebookData)?["cells"]?.arrayOfObjects
    }

    /// Reads a cell's `source` field, tolerating either form nbformat
    /// permits (a single string, or an array of strings to be joined).
    /// Returns an empty string for missing / wrong-type fields, and for an
    /// array with an element that is not a string.
    ///
    /// `NotebookCellView.source` states the same rule for the read-only
    /// walkers. Keep the two the same.
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
