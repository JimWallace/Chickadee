// APIServer/Services/NotebookSubstitution.swift
//
// Walks a Jupyter notebook (.ipynb JSON) and replaces `{{name}}` markers
// in code cells with `repr(value)` literals from a substitutions map.
// Tags each rewritten cell with `metadata.chickadee_personalized = "<name>"`
// so future re-substitutions only touch fenced cells — student edits to
// non-fenced cells are preserved across resets.
//
// Slice 1 of #461: substitution sources are static (global + section
// variables).  Slice 2 will keep the same apply() API but feed it
// per-student values from the PersonalizationEvaluator.

import Foundation

enum NotebookSubstitutionError: Error {
    case notValidNotebookJSON
    case reencodeFailed
    case unknownPlaceholder(name: String)
}

enum NotebookSubstitution {

    /// Metadata key stamped on every cell we rewrite.  Future re-runs only
    /// touch cells carrying this key so student edits to other cells
    /// survive.  Value is the variable name (so a cell rewritten for
    /// `{{ciphertext}}` is tagged `chickadee_personalized: "ciphertext"`).
    static let fencedCellMetadataKey = "chickadee_personalized"

    /// Regex that matches `{{identifier}}` — only valid Python identifier
    /// characters between the braces, no spaces.  Mirrors the validator
    /// used by the editor so the on-disk shape matches what the user typed.
    private static let placeholderRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}"#)
    }()

    /// Applies `substitutions` to the notebook in `notebookData`.
    /// Returns the rewritten notebook as Data (re-serialised JSON).
    ///
    /// Behaviour:
    /// - Each code cell is scanned for `{{name}}` markers.  Markers whose
    ///   name appears in `substitutions` are replaced with the matching
    ///   pythonLiteral string in place.  Markers whose name is NOT in the
    ///   map cause `NotebookSubstitutionError.unknownPlaceholder` to be
    ///   thrown when `strict` is true; when `strict` is false, unknown
    ///   markers are left verbatim (used at student first-open, where the
    ///   save-time scan should have caught all unknowns already).
    /// - Cells that were rewritten get `metadata.chickadee_personalized`
    ///   set to a comma-separated list of substituted names.
    /// - Cells with no `{{name}}` markers are left untouched.
    /// - Non-code cells (markdown, raw) are skipped — Phase 1 scope is
    ///   code-cell substitution only.
    /// - Malformed notebooks throw `notValidNotebookJSON`.
    static func apply(
        notebookData: Data,
        substitutions: [String: String],
        strict: Bool = false
    ) throws -> Data {
        guard
            var notebook = (try? JSONSerialization.jsonObject(with: notebookData))
                as? [String: Any]
        else {
            throw NotebookSubstitutionError.notValidNotebookJSON
        }
        guard var cells = notebook["cells"] as? [[String: Any]] else {
            // Notebook without a cells array — leave alone.
            return notebookData
        }

        for (idx, cell) in cells.enumerated() {
            guard let cellType = cell["cell_type"] as? String, cellType == "code" else {
                continue
            }
            let originalSource = readCellSource(cell)
            let (rewritten, substituted) = try applyToCellSource(
                originalSource,
                substitutions: substitutions,
                strict: strict
            )
            guard !substituted.isEmpty || rewritten != originalSource else { continue }

            var updated = cell
            // Store source back in the same shape it came in (array of strings
            // preserves nbformat's preference; string round-trips fine too).
            if cell["source"] is [String] {
                updated["source"] = splitSourceForArrayShape(rewritten)
            } else {
                updated["source"] = rewritten
            }

            // Tag the cell so subsequent re-substitutions know it's fenced.
            // Preserve any existing metadata.
            var metadata = (updated["metadata"] as? [String: Any]) ?? [:]
            metadata[fencedCellMetadataKey] = Array(substituted).sorted().joined(separator: ",")
            updated["metadata"] = metadata

            cells[idx] = updated
        }
        notebook["cells"] = cells

        guard let encoded = try? JSONSerialization.data(withJSONObject: notebook) else {
            throw NotebookSubstitutionError.reencodeFailed
        }
        return encoded
    }

    /// Returns the list of placeholder names appearing in `notebookData`.
    /// Used at save time to scan a starter notebook and surface unknown
    /// `{{...}}` references as 400 errors.  Always returns deduplicated,
    /// sorted output.
    static func placeholderNames(in notebookData: Data) -> [String] {
        guard
            let notebook = (try? JSONSerialization.jsonObject(with: notebookData))
                as? [String: Any]
        else { return [] }
        guard let cells = notebook["cells"] as? [[String: Any]] else { return [] }
        var found = Set<String>()
        for cell in cells {
            guard let cellType = cell["cell_type"] as? String, cellType == "code" else {
                continue
            }
            let source = readCellSource(cell)
            let nsSource = source as NSString
            let range = NSRange(location: 0, length: nsSource.length)
            placeholderRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                let nameRange = match.range(at: 1)
                if nameRange.location != NSNotFound {
                    found.insert(nsSource.substring(with: nameRange))
                }
            }
        }
        return found.sorted()
    }

    // MARK: - Private helpers

    private static func readCellSource(_ cell: [String: Any]) -> String {
        if let s = cell["source"] as? String { return s }
        if let arr = cell["source"] as? [String] { return arr.joined() }
        return ""
    }

    /// nbformat allows `source` to be either a single string or an array
    /// of strings (each typically ending in `\n`).  When we rewrite a
    /// cell whose original was an array, preserve that shape by
    /// re-splitting on newlines and re-appending `\n` to all but the
    /// last line (which keeps the final-newline status of the original).
    private static func splitSourceForArrayShape(_ source: String) -> [String] {
        let parts = source.components(separatedBy: "\n")
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            if i == parts.count - 1 {
                if !part.isEmpty { out.append(part) }
            } else {
                out.append(part + "\n")
            }
        }
        return out
    }

    /// Performs the in-string substitution.  Returns the rewritten text
    /// and the set of substituted variable names.  Throws on unknown
    /// placeholder when `strict`.
    private static func applyToCellSource(
        _ source: String,
        substitutions: [String: String],
        strict: Bool
    ) throws -> (String, Set<String>) {
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        let matches = placeholderRegex.matches(in: source, options: [], range: range)
        guard !matches.isEmpty else { return (source, []) }

        var substituted: Set<String> = []
        // Walk matches in reverse so earlier replacement ranges stay valid.
        var working = nsSource
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let nameRange = match.range(at: 1)
            let name = working.substring(with: nameRange)
            if let literal = substitutions[name] {
                working = working.replacingCharacters(in: match.range, with: literal) as NSString
                substituted.insert(name)
            } else if strict {
                throw NotebookSubstitutionError.unknownPlaceholder(name: name)
            }
        }
        return (working as String, substituted)
    }
}
