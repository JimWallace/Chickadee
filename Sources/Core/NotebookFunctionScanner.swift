// Core/NotebookFunctionScanner.swift
//
// Scans Jupyter notebook (.ipynb) JSON for top-level Python function definitions.
// Returns a lightweight description of each public function found.
//
// Used by the server to auto-generate test script stubs from a solution notebook.
// No Vapor dependency — pure Foundation.

import Foundation

// MARK: - Model

/// Information extracted from a single Python `def` statement.
public struct NotebookFunctionInfo: Codable, Sendable {
    /// The function name (only non-private, i.e. not starting with `_`).
    public let name: String
    /// Parameter names, excluding `self`, `cls`, `*args`, `**kwargs`.
    public let paramNames: [String]
    /// True if at least one parameter has a type annotation or `->` return hint.
    public let hasTypeHints: Bool
    /// True if a docstring appears in the first few lines of the function body.
    public let hasDocstring: Bool

    public var paramCount: Int { paramNames.count }

    public init(name: String, paramNames: [String], hasTypeHints: Bool, hasDocstring: Bool) {
        self.name = name
        self.paramNames = paramNames
        self.hasTypeHints = hasTypeHints
        self.hasDocstring = hasDocstring
    }
}

// MARK: - Public API

/// Scans a Jupyter notebook (`.ipynb`) for top-level Python function definitions.
///
/// - Parameter notebookData: Raw bytes of the `.ipynb` JSON file.
/// - Returns: One `NotebookFunctionInfo` per public top-level function, in
///   encounter order across all code cells.
public func scanNotebookForFunctions(_ notebookData: Data) -> [NotebookFunctionInfo] {
    guard
        let notebook = try? JSONSerialization.jsonObject(with: notebookData) as? [String: Any],
        let cells = notebook["cells"] as? [[String: Any]]
    else { return [] }

    return cells.flatMap { cell -> [NotebookFunctionInfo] in
        guard (cell["cell_type"] as? String) == "code" else { return [] }
        let source = cellSource(cell)
        return extractTopLevelFunctions(from: source)
    }
}

// MARK: - Private helpers

/// Joins the `source` field of a notebook cell into a single string.
/// The field may be a `[String]` (array of lines) or a plain `String`.
private func cellSource(_ cell: [String: Any]) -> String {
    if let lines = cell["source"] as? [String] {
        return lines.joined()
    }
    return (cell["source"] as? String) ?? ""
}

/// Parses all top-level (no leading indentation) `def` statements in `source`.
/// Private functions (names starting with `_`) are excluded.
private func extractTopLevelFunctions(from source: String) -> [NotebookFunctionInfo] {
    let lines = source.components(separatedBy: "\n")
    var results: [NotebookFunctionInfo] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]
        // Top-level means no leading whitespace.
        guard !line.isEmpty,
              !line.hasPrefix(" "),
              !line.hasPrefix("\t"),
              line.hasPrefix("def ") else {
            i += 1
            continue
        }
        let bodyLines = Array(lines.dropFirst(i + 1))
        if let info = parseFunctionDef(line, bodyLines: bodyLines), !info.name.hasPrefix("_") {
            results.append(info)
        }
        i += 1
    }
    return results
}

/// Attempts to parse a `def name(params...) [-> ret]:` line.
/// Returns `nil` if the line does not match.
private func parseFunctionDef(_ line: String, bodyLines: [String]) -> NotebookFunctionInfo? {
    // Pattern: def <identifier>(<anything>)
    // The params may be followed by `-> returnType` and optionally `:`.
    // We capture everything up to the first unmatched `)` for simplicity.
    let pattern = #"^def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange   = Range(match.range(at: 1), in: line),
          let paramsRange = Range(match.range(at: 2), in: line)
    else { return nil }

    let name      = String(line[nameRange])
    let paramsRaw = String(line[paramsRange])

    let hasTypeHints = paramsRaw.contains(":") || line.contains("->")
    let paramNames   = parseParamNames(from: paramsRaw)
    let hasDocstring = bodyLines.prefix(5).contains {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("\"\"\"") || t.hasPrefix("'''")
    }

    return NotebookFunctionInfo(
        name: name,
        paramNames: paramNames,
        hasTypeHints: hasTypeHints,
        hasDocstring: hasDocstring
    )
}

/// Parses a raw parameter list string (the content between `(` and `)`) into
/// a list of parameter names, stripping type annotations, default values,
/// and ignoring `self`, `cls`, `*args`, `**kwargs`, and `/`.
private func parseParamNames(from raw: String) -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }

    return trimmed
        .split(separator: ",")
        .compactMap { part -> String? in
            var param = part.trimmingCharacters(in: .whitespaces)

            // Strip type annotation: "x: int" → "x"
            if let colonIdx = param.firstIndex(of: ":") {
                param = String(param[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            }
            // Strip default value: "x=0" → "x"
            if let eqIdx = param.firstIndex(of: "=") {
                param = String(param[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            }
            // Skip *args, **kwargs, and the keyword-only marker (*).
            // Any parameter starting with * is variadic or positional-only — exclude it.
            guard !param.hasPrefix("*") else { return nil }

            // Skip special names and the positional-only separator
            guard !param.isEmpty, param != "/", param != "self", param != "cls" else { return nil }

            // Must be a valid Python identifier
            guard
                let first = param.first,
                first.isLetter || first == "_",
                param.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { return nil }

            return param
        }
}
