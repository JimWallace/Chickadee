// APIServer/Utilities/NotebookOutputs.swift
//
// Clears what running a notebook adds to its code cells, so a starter
// notebook reaches students without the author's results in it.
//
// An author runs their starter while writing it, and JupyterLab saves the
// outputs into the file. If those outputs were stored, every student's copy
// would open showing them: the answer to "what does this cell print" before the
// student has run anything. Each write of a starter notebook passes through
// `stripped(_:)` (via `starterNotebookForStorage`), and the one-time
// `StripStarterNotebookOutputs` migration cleaned the notebooks stored before
// that.
//
// The solution notebook is NOT passed through this. It is staff-facing, and
// how a revealed solution reaches students is its own question.
//
// Kept apart from `normalizeNotebookForJupyterLite` on purpose: that function
// also runs when a student's own working copy is read back, and stripping
// there would delete the student's outputs.

import Core
import Foundation

enum NotebookOutputs {

    /// `data` with every code cell's outputs emptied, its execution count set
    /// to null and its `metadata.execution` timing removed.
    ///
    /// The `outputs` and `execution_count` keys stay, as empty values: nbformat
    /// requires both on a code cell. Markdown and raw cells are untouched; a
    /// markdown cell's attachments are authored content, not output.
    ///
    /// Returns `data` itself, byte for byte, when nothing needed clearing or
    /// when it does not parse as a notebook, so a clean notebook is never
    /// rewritten.
    static func stripped(_ data: Data) -> Data {
        guard var notebook = JSONValue.object(from: data),
            let cells = notebook["cells"]?.arrayValue
        else { return data }
        var changed = false
        notebook["cells"] = .array(
            cells.map { cell in
                guard let fields = cell.objectValue else { return cell }
                let cleared = clearingRunState(fields)
                if cleared != fields { changed = true }
                return .object(cleared)
            })
        guard changed else { return data }
        return JSONValue.data(fromObject: notebook) ?? data
    }

    /// One cell with what running it adds cleared: for a code cell, empty
    /// `outputs`, a null `execution_count` and no `metadata.execution`. Any
    /// other cell is returned as it is.
    ///
    /// The one definition of "what running a cell adds". `stripped(_:)` uses
    /// it on the stored bytes, and `sameDraftContent` uses it to decide that a
    /// draft that was only run is not edited, so the two cannot disagree.
    static func clearingRunState(_ cell: [String: JSONValue]) -> [String: JSONValue] {
        guard cell["cell_type"]?.stringValue == "code" else { return cell }
        var fields = cell
        fields["outputs"] = .array([])
        fields["execution_count"] = .null
        if var metadata = fields["metadata"]?.objectValue, metadata["execution"] != nil {
            metadata["execution"] = nil
            fields["metadata"] = .object(metadata)
        }
        return fields
    }
}
