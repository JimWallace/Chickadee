// APIServer/Utilities/ProseParagraphs.swift
//
// Splits free text into paragraphs so a page can render prose (a student's
// written answer, staff feedback) as `<p>` elements instead of a
// preformatted block. Used by AI-assisted feedback
// (docs/ai-assisted-feedback.md).

import Foundation

enum ProseParagraphs {
    /// `text` split at blank lines, each paragraph trimmed, empty ones dropped.
    static func split(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
