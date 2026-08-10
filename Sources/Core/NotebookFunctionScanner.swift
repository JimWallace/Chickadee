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
    /// A required decode key since the v0.6.0-cleanup removal of its
    /// `decodeIfPresent ?? false` fallback.
    public let isShadowed: Bool

    public var paramCount: Int { paramNames.count }

    /// `paramTypes` and `paramHasDefault` must be aligned with `paramNames`
    /// (one entry per parameter).  The pre-0.5 length-realignment shim for
    /// callers that omitted them is gone — every constructor passes the full
    /// arrays.  (The `init(from:)` decode path keeps its absent-array
    /// tolerance: that is a wire contract, pinned by its own tests.)
    public init(
        name: String,
        paramNames: [String],
        paramTypes: [String?],
        paramHasDefault: [Bool],
        returnType: String?,
        hasTypeHints: Bool,
        hasDocstring: Bool,
        isShadowed: Bool = false
    ) {
        self.name = name
        self.paramNames = paramNames
        self.paramTypes = paramTypes
        self.paramHasDefault = paramHasDefault
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
        isShadowed = try c.decode(Bool.self, forKey: .isShadowed)
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
    /// Non-nil when the scan did not run because the assignment's language
    /// cannot be read — see `notebookFunctionScanSupport(for:)`.
    ///
    /// The distinction this field exists to carry: "this solution defines no
    /// functions" and "we cannot read this language" both produced an empty
    /// `functions` array, so an R author was told their solution was empty.
    /// Defaulted to nil so the raw Python scanner's own construction is
    /// unchanged.
    public let unsupportedReason: String?
    public init(
        sectionNames: [String],
        functions: [NotebookFunctionScanEntry],
        unsupportedReason: String? = nil
    ) {
        self.sectionNames = sectionNames
        self.functions = functions
        self.unsupportedReason = unsupportedReason
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
///
/// THE RAW PYTHON IMPLEMENTATION. It reads `def` statements and knows no
/// other language. Production code calls the language-aware overload
/// `scanNotebookForSectionsAndFunctions(_:language:)` instead, which answers
/// "cannot read this language" rather than "found nothing".
public func scanNotebookForSectionsAndFunctions(
    _ notebookData: Data, parsing language: AssignmentLanguage = .python
) -> NotebookScanResult {
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
            let fns = extractTopLevelFunctions(from: source, language: language)
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

/// Parses all top-level (no leading indentation) definitions in `source`.
/// Private functions (names starting with `_`) are excluded.
///
/// THE TRAVERSAL IS ONE IMPLEMENTATION; only the per-line parse varies. Walking
/// cells, tracking the current `## ` header, deduping and marking shadowed
/// redefinitions are language-independent, and copying them per language would
/// be five chances to diverge on the part that has nothing to do with syntax.
private func extractTopLevelFunctions(
    from source: String, language: AssignmentLanguage = .python
) -> [NotebookFunctionInfo] {
    let lines = source.components(separatedBy: "\n")
    var results: [NotebookFunctionInfo] = []

    for (index, line) in lines.enumerated() {
        // Top-level means no leading whitespace, in every language here.
        guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
        let bodyLines = Array(lines.dropFirst(index + 1))
        if let info = parseDefinition(line, bodyLines: bodyLines, language: language),
            !info.name.hasPrefix("_")
        {
            results.append(info)
        }
    }
    return results
}

/// One definition line, in `language`, or nil when the line is not one.
///
/// The syntax comes from `LanguageDescriptor.functionScan`, which CARRIES the
/// patterns rather than claiming a capability implemented elsewhere. A seventh
/// language either supplies them or declares `noSolutionNotebook`; there is no
/// answer that compiles and does nothing.
private func parseDefinition(
    _ line: String, bodyLines: [String], language: AssignmentLanguage
) -> NotebookFunctionInfo? {
    switch language.descriptor.functionScan {
    case .pythonDefStatements:
        // The only syntax whose parser recovers more than a name and
        // parameters: annotations, defaults, return type and a docstring,
        // because Python is the only one of the six that writes them.
        return parseFunctionDef(line, bodyLines: bodyLines)
    case .definitionPatterns(let patterns):
        for pattern in patterns {
            if let info = parseAssignmentStyleDefinition(line, pattern: pattern) { return info }
        }
        return nil
    case .noSolutionNotebook:
        // Upload-only: unreachable through the language-aware entry point,
        // which refuses before reaching here.
        return nil
    }
}

/// One `definitionPatterns` alternative: a regex whose group 1 is the function
/// name and group 2 is the raw parameter list.
///
/// `parseParams` is reused verbatim. Its `x = 0` default-stripping is correct
/// for all three (R and Lua and Octave all spell defaults with `=`), and its
/// `x: int` type-stripping simply never fires, since none of them writes one.
private func parseAssignmentStyleDefinition(
    _ line: String, pattern: String
) -> NotebookFunctionInfo? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let nameRange = Range(match.range(at: 1), in: line),
        let paramsRange = Range(match.range(at: 2), in: line)
    else { return nil }

    let parsedParams = parseParams(from: String(line[paramsRange]))
    return NotebookFunctionInfo(
        name: String(line[nameRange]),
        paramNames: parsedParams.map(\.name),
        paramTypes: parsedParams.map { _ in nil },
        paramHasDefault: parsedParams.map(\.hasDefault),
        returnType: nil,
        hasTypeHints: false,
        hasDocstring: false
    )
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

// MARK: - Language support
//
// The scanner above reads Python `def` statements and nothing else. That was
// fine while every assignment was Python and quietly wrong afterwards: no R,
// Lua, Octave or Racket source contains a line beginning `def `, so the scan
// returned no functions and the instructor read "No functions found." on a
// perfectly good solution. Empty and unsupported are different answers and only
// one of them is the author's problem.
//
// The support question is EXHAUSTIVE so a seventh language has to answer it. The
// compiler cannot force anyone to write an R parser — what it can force is that
// somebody decides, and that the decision is visible to the instructor instead
// of being inherited as silence.

/// Whether `scanNotebookForSectionsAndFunctions` can find function definitions
/// written in a given language.
public enum NotebookFunctionScanSupport: Sendable, Equatable {
    /// The scanner reads this language's function definitions.
    case supported
    /// It does not, and this is what to tell the instructor. Phrased for
    /// display: it names the language and says what would be needed, so the
    /// message is actionable rather than a shrug.
    case unsupported(reason: String)

    public var isSupported: Bool { self == .supported }

    /// The instructor-facing reason, or nil when scanning works.
    public var unsupportedReason: String? {
        switch self {
        case .supported: return nil
        case .unsupported(let reason): return reason
        }
    }
}

/// Whether the solution-notebook function scan works for `language`.
///
/// EXHAUSTIVE ON PURPOSE — this is the decision a seventh language must make.
/// Answering `.supported` without a parser to back it reinstates exactly the
/// silence this type exists to end, so the arm and the parser move together.
public func notebookFunctionScanSupport(
    for language: AssignmentLanguage?
) -> NotebookFunctionScanSupport {
    // No language means a plain `.sh` suite: there is no notebook workflow to
    // scan and nothing to promise. Treated as unsupported so the caller says so
    // rather than reporting an empty scan.
    guard let language else {
        return .unsupported(
            reason: "This assignment declares no language, so there is no solution notebook to scan.")
    }
    // DERIVED from the descriptor's syntax, which carries the patterns. There
    // is no separate list of "languages we can scan" to fall out of step with
    // the parsers — supplying patterns IS declaring support.
    switch language.descriptor.functionScan {
    case .pythonDefStatements, .definitionPatterns:
        return .supported
    case .noSolutionNotebook:
        return .unsupported(
            reason: """
                \(language.displayName) assignments are upload-only and have no solution notebook \
                to scan. Add the family's function name and parameters by hand.
                """)
    }
}

/// The language-aware entry point — the one production code should call.
///
/// Returns an empty scan carrying `unsupportedReason` when the language cannot
/// be read, so a caller can tell "this solution defines nothing" from "we cannot
/// read this language" and say which. `scanNotebookForSectionsAndFunctions`
/// remains the raw Python implementation beneath it.
public func scanNotebookForSectionsAndFunctions(
    _ notebookData: Data, language: AssignmentLanguage?
) -> NotebookScanResult {
    let support = notebookFunctionScanSupport(for: language)
    guard support.isSupported else {
        // SECTIONS ARE STILL READ. `unsupportedReason` scopes to `functions`,
        // and only to functions: a section name is a `## ` markdown header,
        // which has nothing to do with the code language. Returning an empty
        // `sectionNames` here denied suite-section scaffolding to five
        // languages as collateral from a limitation that applies to function
        // extraction alone.
        return NotebookScanResult(
            sectionNames: scanNotebookForSectionsAndFunctions(notebookData).sectionNames,
            functions: [],
            unsupportedReason: support.unsupportedReason)
    }
    return scanNotebookForSectionsAndFunctions(notebookData, parsing: language ?? .python)
}
