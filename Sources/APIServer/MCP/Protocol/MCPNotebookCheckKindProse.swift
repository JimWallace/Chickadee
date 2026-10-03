// APIServer/MCP/Protocol/MCPNotebookCheckKindProse.swift
//
// How the notebook-check kinds are SPELLED in the agent-facing copy — the
// `initialize` instructions and the `author_notebook_check` description —
// derived from `NotebookCheckKind.allCases` in one place (#1936).
//
// The sibling of MCPPatternKindProse. Both lists of the ten check kinds were
// typed by hand, four lines from the derived pattern-kind list, so an
// eleventh kind would have been missing from both while the tool's JSON
// `enum` (derived) accepted it.

import Core

/// The notebook-check kinds, rendered for the places agent-facing copy needs
/// them.
enum MCPNotebookCheckKindProse {

    /// One short phrase per kind, for a reader deciding which to reach for.
    ///
    /// EXHAUSTIVE ON PURPOSE: a new kind does not compile until it says what it
    /// is. Keep each to a clause: these are joined into a sentence.
    static func gloss(for kind: NotebookCheckKind) -> String {
        switch kind {
        case .dataFrameShape: return "a data frame has an expected number of rows and columns"
        case .dataFrameColumns: return "a data frame has expected columns"
        case .dataFrameEquality: return "a data frame equals an expected one"
        case .seriesEquality: return "a series equals an expected one"
        case .numericArrayClose: return "a numeric array is within a tolerance of an expected one"
        case .figureCount: return "the notebook produces at least a number of figures"
        case .cellContains: return "a code cell contains given text or matches a pattern"
        case .functionExists: return "a function is defined, optionally with a given arity"
        case .variableExists: return "a variable is defined, optionally with a given type"
        case .astStructure: return "the source uses, or avoids, given constructs such as a loop"
        }
    }

    /// Every kind's wire token, in declaration order.
    static var tokens: [String] { NotebookCheckKind.allCases.map(\.rawValue) }

    /// `"data_frame_shape / data_frame_columns / …"` — the slash-separated form
    /// a tool description uses when listing legal values inline.
    static var slashSeparated: String { tokens.joined(separator: " / ") }

    /// `"data_frame_shape (…), data_frame_columns (…), and …"` — the glossed
    /// sentence form the `initialize` instructions use.
    static var glossedList: String {
        let described = NotebookCheckKind.allCases.map { "\($0.rawValue) (\(gloss(for: $0)))" }
        guard described.count > 1 else { return described.first ?? "" }
        return described.dropLast().joined(separator: ", ") + ", and " + (described.last ?? "")
    }
}
