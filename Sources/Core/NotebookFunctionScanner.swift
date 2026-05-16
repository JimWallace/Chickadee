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
    /// Per-parameter type annotations as written in the source (`nil` when
    /// the param has no annotation).  Length matches `paramNames`.  Used
    /// by the family editor to coerce typed cell values into the right
    /// JSON shape before sending them to the server.
    public let paramTypes: [String?]
    /// `true` at position `i` when parameter `i` has a default value in the
    /// signature (i.e. `foo: str = "x"`).  Length matches `paramNames`.
    /// Used by the family editor to let the instructor leave those cells
    /// empty and have the renderer fall through to the function's own
    /// default at test time, rather than forcing a value for every param.
    public let paramHasDefault: [Bool]
    /// The `-> X` return type annotation, `nil` when absent.  Used by the
    /// family editor to coerce the Expected cell into the right shape.
    public let returnType: String?
    /// True if at least one parameter has a type annotation or `->` return hint.
    public let hasTypeHints: Bool
    /// True if a docstring appears in the first few lines of the function body.
    public let hasDocstring: Bool
    /// True when a later `def <name>` in the notebook redefines this function.
    /// Python has no real overloading — the last definition wins at runtime —
    /// so a family targeting a shadowed version will fail (wrong signature).
    /// Decoded with `decodeIfPresent ?? false` so older clients that don't
    /// send the field still roundtrip.
    public let isShadowed: Bool

    public var paramCount: Int { paramNames.count }

    public init(
        name: String,
        paramNames: [String],
        paramTypes: [String?] = [],
        paramHasDefault: [Bool] = [],
        returnType: String? = nil,
        hasTypeHints: Bool,
        hasDocstring: Bool,
        isShadowed: Bool = false
    ) {
        self.name = name
        self.paramNames = paramNames
        // Keep paramTypes aligned with paramNames even when the caller omitted it
        // (back-compat: older callers constructed this struct without types).
        self.paramTypes =
            paramTypes.count == paramNames.count
            ? paramTypes
            : Array(repeating: nil, count: paramNames.count)
        self.paramHasDefault =
            paramHasDefault.count == paramNames.count
            ? paramHasDefault
            : Array(repeating: false, count: paramNames.count)
        self.returnType = returnType
        self.hasTypeHints = hasTypeHints
        self.hasDocstring = hasDocstring
        self.isShadowed = isShadowed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        paramNames = try c.decode([String].self, forKey: .paramNames)
        hasTypeHints = try c.decode(Bool.self, forKey: .hasTypeHints)
        hasDocstring = try c.decode(Bool.self, forKey: .hasDocstring)
        // DEPRECATED: remove `decodeIfPresent ?? false` fallback in v0.6.0 —
        // by then every browser client will have shipped the v0.4.94+ scanner.
        isShadowed = try c.decodeIfPresent(Bool.self, forKey: .isShadowed) ?? false
        let decodedParamTypes = try c.decodeIfPresent([String?].self, forKey: .paramTypes) ?? []
        paramTypes =
            decodedParamTypes.count == paramNames.count
            ? decodedParamTypes
            : Array(repeating: nil, count: paramNames.count)
        let decodedParamHasDefault = try c.decodeIfPresent([Bool].self, forKey: .paramHasDefault) ?? []
        paramHasDefault =
            decodedParamHasDefault.count == paramNames.count
            ? decodedParamHasDefault
            : Array(repeating: false, count: paramNames.count)
        returnType = try c.decodeIfPresent(String.self, forKey: .returnType)
    }
}

// MARK: - Public API

/// Scans a Jupyter notebook (`.ipynb`) for top-level Python function definitions.
///
/// - Parameter notebookData: Raw bytes of the `.ipynb` JSON file.
/// - Returns: One `NotebookFunctionInfo` per public top-level function, in
///   encounter order across all code cells.
/// Result of a section-aware notebook scan (v0.4.100+).  Pairs each
/// detected function with the name of the `## `-level markdown section
/// whose header most recently preceded it in the notebook.  Functions
/// appearing before any `##` header get `sectionName == nil`.
///
/// `sectionNames` is the ordered, deduplicated list of `##` headers in
/// first-appearance order — used by the create workflow to scaffold
/// `TestSuiteSection` entries.
public struct NotebookScanResult: Sendable {
    public let sectionNames: [String]
    public let functions: [NotebookFunctionScanEntry]
    public init(sectionNames: [String], functions: [NotebookFunctionScanEntry]) {
        self.sectionNames = sectionNames
        self.functions = functions
    }
}

public struct NotebookFunctionScanEntry: Sendable {
    public let info: NotebookFunctionInfo
    /// The `##` header text of the section containing this function.
    /// `nil` when the function appears before any `##` header in the notebook.
    public let sectionName: String?
    public init(info: NotebookFunctionInfo, sectionName: String?) {
        self.info = info
        self.sectionName = sectionName
    }
}

/// Walks the notebook cell-by-cell, tracking the current `## ` markdown
/// section as it goes, and tags each detected function with that header.
/// Deduplicates section names in first-appearance order.  Shares the
/// single-cell function extractor with `scanNotebookForFunctions` so
/// the two paths agree on what counts as a detected function.
public func scanNotebookForSectionsAndFunctions(_ notebookData: Data) -> NotebookScanResult {
    guard
        let notebook = try? JSONSerialization.jsonObject(with: notebookData) as? [String: Any],
        let cells = notebook["cells"] as? [[String: Any]]
    else { return NotebookScanResult(sectionNames: [], functions: []) }

    var sectionsInOrder: [String] = []
    var seenSections: Set<String> = []
    var currentSection: String?
    var entries: [NotebookFunctionScanEntry] = []
    var rawEntriesByName: [String: Int] = [:]  // for shadowing pass below

    for cell in cells {
        let cellType = cell["cell_type"] as? String
        let source = cellSource(cell)
        if cellType == "markdown" {
            // First `##` line (not `###`+) becomes the current section.
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") {
                    let title = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { continue }
                    currentSection = title
                    if seenSections.insert(title).inserted {
                        sectionsInOrder.append(title)
                    }
                    break  // one section set per cell; ignore subsequent #s
                }
            }
        } else if cellType == "code" {
            let fns = extractTopLevelFunctions(from: source)
            for fn in fns {
                rawEntriesByName[fn.name] = entries.count
                entries.append(NotebookFunctionScanEntry(info: fn, sectionName: currentSection))
            }
        }
    }

    // Mark later redefinitions as shadowing earlier ones — same logic
    // as `scanNotebookForFunctions`, just applied to our richer entry.
    let shadowed: [NotebookFunctionScanEntry] = entries.enumerated().map { idx, entry in
        let last = rawEntriesByName[entry.info.name] ?? idx
        let info = entry.info
        let withShadow = NotebookFunctionInfo(
            name: info.name,
            paramNames: info.paramNames,
            paramTypes: info.paramTypes,
            paramHasDefault: info.paramHasDefault,
            returnType: info.returnType,
            hasTypeHints: info.hasTypeHints,
            hasDocstring: info.hasDocstring,
            isShadowed: last != idx
        )
        return NotebookFunctionScanEntry(info: withShadow, sectionName: entry.sectionName)
    }

    return NotebookScanResult(sectionNames: sectionsInOrder, functions: shadowed)
}

public func scanNotebookForFunctions(_ notebookData: Data) -> [NotebookFunctionInfo] {
    guard
        let notebook = try? JSONSerialization.jsonObject(with: notebookData) as? [String: Any],
        let cells = notebook["cells"] as? [[String: Any]]
    else { return [] }

    let raw: [NotebookFunctionInfo] = cells.flatMap { cell -> [NotebookFunctionInfo] in
        guard (cell["cell_type"] as? String) == "code" else { return [] }
        let source = cellSource(cell)
        return extractTopLevelFunctions(from: source)
    }

    // Python's second `def foo(...)` replaces the first at runtime — every
    // entry except the *last* occurrence of each name is shadowed.  Mark them
    // so the client can warn the instructor away from targeting a version
    // the runner will never see.
    var lastIndexByName: [String: Int] = [:]
    for (i, info) in raw.enumerated() {
        lastIndexByName[info.name] = i
    }
    return raw.enumerated().map { idx, info in
        let shadowed = (lastIndexByName[info.name] ?? idx) != idx
        return NotebookFunctionInfo(
            name: info.name,
            paramNames: info.paramNames,
            paramTypes: info.paramTypes,
            paramHasDefault: info.paramHasDefault,
            returnType: info.returnType,
            hasTypeHints: info.hasTypeHints,
            hasDocstring: info.hasDocstring,
            isShadowed: shadowed
        )
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
            line.hasPrefix("def ")
        else {
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
        let nameRange = Range(match.range(at: 1), in: line),
        let paramsRange = Range(match.range(at: 2), in: line)
    else { return nil }

    let name = String(line[nameRange])
    let paramsRaw = String(line[paramsRange])

    let hasTypeHints = paramsRaw.contains(":") || line.contains("->")
    let parsedParams = parseParams(from: paramsRaw)
    let paramNames = parsedParams.map(\.name)
    let paramTypes = parsedParams.map(\.type)
    let paramHasDefault = parsedParams.map(\.hasDefault)
    let returnType = parseReturnType(from: line)
    let hasDocstring = bodyLines.prefix(5).contains {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("\"\"\"") || t.hasPrefix("'''")
    }

    return NotebookFunctionInfo(
        name: name,
        paramNames: paramNames,
        paramTypes: paramTypes,
        paramHasDefault: paramHasDefault,
        returnType: returnType,
        hasTypeHints: hasTypeHints,
        hasDocstring: hasDocstring
    )
}

/// A single parsed parameter: name, optional type annotation, and a flag
/// recording whether the signature provides a default value (the expression
/// itself is dropped — the family renderer falls through to Python's own
/// default at runtime instead of embedding the literal).
private struct ParsedParam {
    let name: String
    let type: String?
    let hasDefault: Bool
}

/// Parses a raw parameter list string (the content between `(` and `)`) into
/// a list of `(name, type?, hasDefault)` triples, stripping the default-value
/// expression but recording its presence, and ignoring `self`, `cls`,
/// `*args`, `**kwargs`, and the keyword-only `/` marker.
private func parseParams(from raw: String) -> [ParsedParam] {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }

    return
        trimmed
        .split(separator: ",")
        .compactMap { part -> ParsedParam? in
            var chunk = part.trimmingCharacters(in: .whitespaces)

            // Strip default value: "x = 0" or "x: int = 0" → type survives,
            // and record the presence of `=` so the editor can mark this
            // column as optional.
            var hasDefault = false
            if let eqIdx = chunk.firstIndex(of: "=") {
                hasDefault = true
                chunk = String(chunk[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            }
            // Split name / type at first `:`.
            var paramName = chunk
            var paramType: String?
            if let colonIdx = chunk.firstIndex(of: ":") {
                paramName = String(chunk[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let t = String(chunk[chunk.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                paramType = t.isEmpty ? nil : t
            }
            // Skip *args, **kwargs, and the keyword-only marker (*).
            guard !paramName.hasPrefix("*") else { return nil }
            guard !paramName.isEmpty, paramName != "/", paramName != "self", paramName != "cls" else { return nil }
            guard
                let first = paramName.first,
                first.isLetter || first == "_",
                paramName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { return nil }

            return ParsedParam(name: paramName, type: paramType, hasDefault: hasDefault)
        }
}

/// Extracts the `-> TYPE` return-type annotation from the signature line.
/// Returns nil if the signature has no return annotation.
private func parseReturnType(from line: String) -> String? {
    // Look for `)` followed by `->` and capture everything up to a trailing
    // colon (the `def` line's terminator).  Generic types with commas or
    // spaces (`dict[str, int]`) are preserved verbatim.
    let pattern = #"\)\s*->\s*(.+?)\s*:\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let range = Range(match.range(at: 1), in: line)
    else { return nil }
    let t = String(line[range]).trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
}
