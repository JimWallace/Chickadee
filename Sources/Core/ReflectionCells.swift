// Core/ReflectionCells.swift
//
// Reads the written-reasoning cells of a notebook for AI-assisted feedback
// (docs/ai-assisted-feedback.md). The instructor marks each reasoning cell in
// the starter notebook with the Jupyter cell tag `reflection`. For each tagged
// starter cell this pairs:
//
//   - the prompt: the nearest markdown cell before it, read from the STARTER,
//     so a student cannot rewrite the question the agent sees;
//   - the response: the matching tagged cell in the student's submission.
//
// A submitted cell matches by its nbformat cell `id` when both notebooks carry
// one, else by its position among the tagged cells. Nothing else in either
// notebook (code, outputs, metadata) leaves this type.

import Foundation

/// One prompt and the student's written response to it.
public struct ReflectionPair: Sendable, Equatable, Codable {
    /// 1-based position among the starter's tagged cells.
    public let index: Int
    /// The question, from the starter notebook. Empty when no markdown cell
    /// comes before the tagged cell.
    public let prompt: String
    /// The student's text, or nil when the submission has no matching cell.
    public let response: String?

    public init(index: Int, prompt: String, response: String?) {
        self.index = index
        self.prompt = prompt
        self.response = response
    }
}

public enum ReflectionCells {
    /// The Jupyter cell tag that marks a reasoning cell.
    public static let tag = "reflection"

    /// The tagged cells of `starter`, each paired with its response in
    /// `submission`. Returns `[]` when the starter is not a notebook or tags
    /// no cell. A submission that is not a notebook yields nil responses.
    public static func pairs(starter: Data, submission: Data?) -> [ReflectionPair] {
        guard let starterCells = NotebookCellSources.cells(from: starter) else { return [] }
        let submittedTagged = submission.flatMap(NotebookCellSources.cells(from:))?.filter(isTagged) ?? []
        let submittedByID = Dictionary(
            submittedTagged.compactMap { cell in cellID(cell).map { ($0, cell) } },
            uniquingKeysWith: { first, _ in first })

        var pairs: [ReflectionPair] = []
        var lastMarkdown = ""
        for cell in starterCells {
            if isTagged(cell) {
                let position = pairs.count
                let match =
                    cellID(cell).flatMap { submittedByID[$0] }
                    ?? (position < submittedTagged.count ? submittedTagged[position] : nil)
                pairs.append(
                    ReflectionPair(
                        index: position + 1,
                        prompt: lastMarkdown,
                        response: match.map(trimmedSource)))
            } else if cell["cell_type"] as? String == "markdown" {
                lastMarkdown = trimmedSource(cell)
            }
        }
        return pairs
    }

    /// True when `notebook` tags at least one cell `reflection`.
    public static func hasTaggedCells(_ notebook: Data) -> Bool {
        NotebookCellSources.cells(from: notebook)?.contains(where: isTagged) ?? false
    }

    private static func isTagged(_ cell: [String: Any]) -> Bool {
        guard let metadata = cell["metadata"] as? [String: Any],
            let tags = metadata["tags"] as? [String]
        else { return false }
        return tags.contains(tag)
    }

    private static func cellID(_ cell: [String: Any]) -> String? {
        guard let id = cell["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private static func trimmedSource(_ cell: [String: Any]) -> String {
        NotebookCellSources.cellSource(cell).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
