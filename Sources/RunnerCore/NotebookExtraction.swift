// RunnerCore notebook extraction — the single source of truth for turning a
// Jupyter notebook's code cells into runnable source (Python via
// `extractPython`, R via `extractR`).
//
// RunnerCore is deliberately dependency-free (Swift stdlib only — no Foundation,
// no Process, no filesystem) so it can compile to `wasm32` and run inside the
// browser runner via a thin JS bridge, exactly as the native worker runs it
// today. Keeping ONE implementation here is what stops the worker and browser
// extractors from drifting (the class of bug behind the HLTH-230 validation
// failures).
//
// Each code cell produces TWO views, computed from the same sanitized body:
//   • executableModule    — the resilient `exec(compile(...))`-per-cell form
//                           that actually runs (one broken cell can't fail the
//                           rest of the module).
//   • introspectableSource — the sanitized real source (module-level `def`s,
//                           side-effects quarantined into `if __name__`) with
//                           NO exec-wrap, so `inspect.getsource` + `ast.parse`
//                           can see the real definitions. Structural-property
//                           NotebookChecks read this.

/// One notebook cell, with its raw (untrimmed) joined source. `cellType` is the
/// notebook's `cell_type` ("code", "markdown", …). Non-code cells are kept in
/// the list so cell numbering matches the original notebook positions.
public struct NotebookCell: Sendable, Equatable {
    public let cellType: String
    public let source: String

    public init(cellType: String, source: String) {
        self.cellType = cellType
        self.source = source
    }
}

public struct ExtractedNotebook: Sendable, Equatable {
    /// The resilient, runnable module (exec(compile()) per cell).
    public let executableModule: String
    /// The sanitized real source for AST / `inspect.getsource` introspection.
    public let introspectableSource: String
    public let codeCellCount: Int

    public init(executableModule: String, introspectableSource: String, codeCellCount: Int) {
        self.executableModule = executableModule
        self.introspectableSource = introspectableSource
        self.codeCellCount = codeCellCount
    }
}

/// Extract Python from a notebook's cells. Produces both the executable module
/// and the introspectable source. Cell labels (`cell N`) use the 1-based index
/// of the cell in the original notebook, matching the prior worker behaviour.
public func extractPython(cells: [NotebookCell], filename: String) -> ExtractedNotebook {
    var execParts: [String] = []
    var sourceParts: [String] = []
    var codeCellCount = 0

    for (index, cell) in cells.enumerated() {
        guard cell.cellType == "code" else { continue }

        let trimmedSource = trimWhitespaceAndNewlines(cell.source)
        guard !trimmedSource.isEmpty else { continue }

        let cellSource = sanitizeCellForModule(trimmedSource)
        guard !trimmedString(cellSource).isEmpty else { continue }

        codeCellCount += 1
        let label = "cell \(index + 1)"
        execParts.append("# --- \(label) ---\n\(wrapCellForResilientLoad(cellSource, label: label))")
        sourceParts.append("# --- \(label) ---\n\(cellSource)")
    }

    let header = "# Generated from \(filename)\n\n"
    let executableModule =
        execParts.isEmpty ? "" : header + execParts.joined(separator: "\n\n") + "\n"
    let introspectableSource =
        sourceParts.isEmpty ? "" : header + sourceParts.joined(separator: "\n\n") + "\n"

    return ExtractedNotebook(
        executableModule: executableModule,
        introspectableSource: introspectableSource,
        codeCellCount: codeCellCount
    )
}

// MARK: - R extraction (shared by both runners)

/// One R notebook flattened to a `.R` module. Unlike `ExtractedNotebook` there
/// is no separate introspectable view: R cells are emitted verbatim (no
/// exec-wrap), so the one output serves both execution and source-level checks.
public struct ExtractedRNotebook: Sendable, Equatable {
    /// Header + a boundary marker per kept cell + the cell's source. Markers
    /// are inert R comments; the grading runtime's `chickadee_student_cells()`
    /// splits on them to recover cell granularity.
    public let source: String
    public let codeCellCount: Int

    public init(source: String, codeCellCount: Int) {
        self.source = source
        self.codeCellCount = codeCellCount
    }
}

/// Extract R from a notebook's cells: each non-empty code cell is emitted
/// verbatim (trailing whitespace trimmed) behind a `rCellBoundaryMarker` line.
/// Marker numbers use the 1-based position of the cell in the original
/// notebook — a markdown cell between two code cells shows as a gap rather
/// than silently renumbering. Byte-identical to the extraction the native
/// worker performed inline before the hoist (PR #1235), including the
/// header-only output for a notebook with no code cells.
public func extractR(cells: [NotebookCell], filename: String) -> ExtractedRNotebook {
    extractWithCellMarkers(cells: cells, filename: filename, comment: "#")
}

/// Extract Lua from a notebook's cells. Identical in shape to `extractR` —
/// verbatim cells behind an inert boundary comment — because both languages
/// need the same thing and for the same reason: a flattened source file that a
/// source-level notebook check can still split back into cells.
///
/// Only the comment marker differs (`--` rather than `#`), which is why the two
/// share `extractWithCellMarkers` instead of being two copies that can drift.
/// Python is genuinely different and keeps its own implementation: it labels
/// cells via `wrapCellForResilientLoad` rather than by comment, so a failing
/// cell does not take the rest of the module with it.
public func extractLua(cells: [NotebookCell], filename: String) -> ExtractedRNotebook {
    extractWithCellMarkers(cells: cells, filename: filename, comment: "--")
}

/// Extract Octave from a notebook's cells — the third marker-based extractor,
/// `%` being Octave's comment leader. The flattened file is NOT given a `1;`
/// script guard here: it is only ever executed through the grading runtime's
/// `chickadee.load_student()`, which evaluates the text with the guard
/// prepended, so the file on disk stays exactly the cells a `cellContains`
/// check reads.
public func extractOctave(cells: [NotebookCell], filename: String) -> ExtractedRNotebook {
    extractWithCellMarkers(cells: cells, filename: filename, comment: "%")
}

/// Extract C++ from a notebook's cells — the fourth marker-based extractor,
/// `//` being C++'s comment leader. C++ assignments are upload-only with no
/// notebook workflow, so this path is rare (a student uploading an `.ipynb`
/// through the upload form), but the submission guarantees hold uniformly:
/// a notebook that arrives extracts or errors, never silently vanishes.
public func extractCpp(cells: [NotebookCell], filename: String) -> ExtractedRNotebook {
    extractWithCellMarkers(cells: cells, filename: filename, comment: "//")
}

/// The shared body of the marker-based extractors. Emits each non-empty code
/// cell verbatim (trailing whitespace trimmed) behind a boundary comment whose
/// number is the cell's 1-based position in the ORIGINAL notebook — a markdown
/// cell between two code cells shows as a gap rather than silently renumbering.
///
/// Byte-identical to the extraction the native worker performed inline before
/// the hoist (PR #1235), including the header-only output for a notebook with
/// no code cells.
private func extractWithCellMarkers(
    cells: [NotebookCell], filename: String, comment: String
) -> ExtractedRNotebook {
    var output = "\(comment) Generated from \(filename)\n\n"
    var codeCellCount = 0
    for (index, cell) in cells.enumerated() {
        guard cell.cellType == "code" else { continue }
        var src = cell.source
        while src.last?.isWhitespace == true { src.removeLast() }
        guard !src.isEmpty else { continue }
        codeCellCount += 1
        output += cellBoundaryMarker(cellNumber: index + 1, comment: comment) + "\n"
        output += src + "\n\n"
    }
    return ExtractedRNotebook(source: output, codeCellCount: codeCellCount)
}

private func cellBoundaryMarker(cellNumber: Int, comment: String) -> String {
    "\(comment) ---- chickadee:cell \(cellNumber) ----"
}

/// Comment line the R extraction writes ahead of each code cell, so the
/// flattened `.R` file keeps the cell granularity a source-level notebook check
/// needs. It is an ordinary R comment, so it is inert when the submission runs.
///
/// The grading side splits on this in `chickadee_student_cells()`
/// (`testRuntimeRStudentFile`, mirrored in `Tools/runner-support/test_runtime.R`).
/// `NotebookExtractorRCellMarkerTests` pins the two against each other.
public func rCellBoundaryMarker(cellNumber: Int) -> String {
    cellBoundaryMarker(cellNumber: cellNumber, comment: "#")
}

/// The Lua counterpart, split back out by `chickadee_student_cells()` in
/// `Tools/runner-support/test_runtime.lua`. `NotebookExtractorLuaCellMarkerTests`
/// pins the two against each other, as the R pair is pinned.
public func luaCellBoundaryMarker(cellNumber: Int) -> String {
    cellBoundaryMarker(cellNumber: cellNumber, comment: "--")
}

/// The Octave counterpart, split back out by `chickadee.student_cells()` in
/// `Tools/runner-support/test_runtime.m`.
public func octaveCellBoundaryMarker(cellNumber: Int) -> String {
    cellBoundaryMarker(cellNumber: cellNumber, comment: "%")
}

/// Regex the runtime uses to recognize a marker line. Kept beside the writer
/// so the two are defined together; the runtime spells it out literally
/// because `Tools/runner-support/test_runtime.R` is a byte-for-byte mirror.
public let rCellBoundaryMarkerPattern = "^# ---- chickadee:cell [0-9]+ ----$"

/// The Lua equivalent. Spelled out literally for the same reason: the runtime
/// that consumes it is a byte-for-byte mirror and cannot import this.
public let luaCellBoundaryMarkerPattern = "^%-%- ---- chickadee:cell %d+ ----$"

// MARK: - Per-cell transforms (shared by both runners)

/// Sanitizes a single notebook code cell for use as a module-level Python
/// source block:
///   • IPython magic (`%…`) and shell pass-through (`!…`) lines are stripped.
///   • Definitions / imports / constants stay at module level (so functions and
///     module constants remain importable).
///   • Side-effecting / control-flow statements are quarantined inside
///     `if __name__ == "__main__":` so they don't run at import but stay visible.
///   • Bracket depth is tracked across lines so continuation lines of a
///     multi-line statement aren't re-classified as new statements.
public func sanitizeCellForModule(_ source: String) -> String {
    // Strip magic/shell lines first.
    let lines = splitLines(source).filter { line in
        let s = trimSpacesAndTabs(line)
        return !s.hasPrefix("%") && !s.hasPrefix("!")
    }

    var defLines: [String] = []
    var usageLines: [String] = []
    var inUsage = false
    var lex = CellLexState()

    for line in lines {
        let trimmed = trimSpacesAndTabs(line)
        // A new top-level statement begins only when we are NOT inside open
        // brackets AND NOT inside a triple-quoted string opened on an earlier
        // line (otherwise the line is a continuation), and the line itself
        // starts in column 0.
        let isTopLevel =
            lex.bracketDepth == 0 && !lex.inTripleString && !line.isEmpty
            && !(line.first?.isWhitespace ?? true)

        // Advance the lexical state AFTER the isTopLevel check — the state must
        // reflect the lines *before* this one. The scan skips string and comment
        // contents so their brackets/quotes can't perturb the classification.
        advanceLexState(line, &lex)

        if isTopLevel && !trimmed.isEmpty {
            inUsage = !isSafeTopLevelStatement(trimmed)
        }

        if inUsage {
            usageLines.append(line)
        } else {
            defLines.append(line)
        }
    }

    var parts: [String] = []

    let defBlock = trimmedString(defLines.joined(separator: "\n"))
    if !defBlock.isEmpty {
        parts.append(defBlock)
    }

    let usageBlock = trimmedString(usageLines.joined(separator: "\n"))
    if !usageBlock.isEmpty {
        let indented =
            splitLines(usageBlock)
            .map { "    " + $0 }
            .joined(separator: "\n")
        parts.append("if __name__ == \"__main__\":\n\(indented)")
    }

    return parts.joined(separator: "\n\n")
}

/// Wraps one cell's sanitized body so it loads independently of every other
/// cell — a syntax or runtime error in one cell is caught and only that cell is
/// skipped. `from __future__` imports must stay at module top, so those cells
/// are emitted unwrapped.
public func wrapCellForResilientLoad(_ body: String, label: String) -> String {
    // `from __future__` imports must stay at module top. Detected line-by-line
    // (hasPrefix) rather than `String.contains(_: String)`, which Embedded Swift
    // lacks (no string-processing module) — RunnerCore compiles to wasm32.
    let hasFutureImport = splitLines(body).contains { line in
        trimSpacesAndTabs(line).hasPrefix("from __future__")
    }
    if hasFutureImport {
        return body
    }
    return """
        try:
            exec(compile(\(pythonStringLiteral(body)), \(pythonStringLiteral(label)), "exec"), globals())
        except Exception:
            pass
        """
}

/// Encodes a Swift string as a Python string literal. We escape exactly the
/// characters Python needs and pass everything else through unchanged. We do
/// NOT use JSON encoding here: it escapes `/` as `\/`, which is not a valid
/// Python escape and breaks the inner `compile()` (regression fixed in v0.4.220).
public func pythonStringLiteral(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += "\\x" + hex2(scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

// MARK: - Cross-line lexical scan

/// Carried lexical state for the per-cell line classifier: how deeply brackets
/// are nested and whether we are currently inside a triple-quoted string. Both
/// can span multiple physical lines, so the state persists across the cell's
/// lines. Single-line strings and `#` comments never span lines, so they are
/// resolved inside `advanceLexState` and never leak into the carried state.
struct CellLexState {
    var bracketDepth = 0
    var inTripleString = false
    var tripleDelimiter: Character = "\""
}

/// Advance `state` across one physical line. Brackets are counted only outside
/// string and comment context, and a triple-quoted string opened here (or on an
/// earlier line) is tracked until its closing delimiter so its interior lines
/// aren't misread as new top-level statements. This is the fix for student cells
/// that park a multi-line `\"\"\"…\"\"\"` block (prose or an alternate solution) at
/// module level: without triple-quote tracking the interior lines were ripped
/// out into the `if __name__` quarantine, producing invalid Python that the
/// resilient-load wrapper then silently dropped — taking every definition and
/// variable in the cell down with it.
func advanceLexState(_ line: String, _ state: inout CellLexState) {
    let chars = Array(line)
    let count = chars.count
    var index = 0
    while index < count {
        let char = chars[index]

        if state.inTripleString {
            if char == state.tripleDelimiter
                && index + 2 < count
                && chars[index + 1] == state.tripleDelimiter
                && chars[index + 2] == state.tripleDelimiter
            {
                state.inTripleString = false
                index += 3
            } else {
                index += 1
            }
            continue
        }

        // Outside any string: `#` starts a comment that runs to end of line.
        if char == "#" { return }

        if char == "\"" || char == "'" {
            // Triple-quoted string opener?
            if index + 2 < count && chars[index + 1] == char && chars[index + 2] == char {
                state.inTripleString = true
                state.tripleDelimiter = char
                index += 3
                continue
            }
            // Single-line string: skip to its matching unescaped quote.
            index += 1
            while index < count {
                if chars[index] == "\\" {
                    index += 2
                    continue
                }
                if chars[index] == char {
                    index += 1
                    break
                }
                index += 1
            }
            continue
        }

        switch char {
        case "(", "[", "{": state.bracketDepth += 1
        case ")", "]", "}": state.bracketDepth = max(0, state.bracketDepth - 1)
        default: break
        }
        index += 1
    }
}

// MARK: - Top-level statement classification

/// True if a non-indented Python statement is safe at module level — it defines
/// something (function, class, import, constant) rather than executing
/// side-effectful or control-flow code.
func isSafeTopLevelStatement(_ rawTrimmed: String) -> Bool {
    // Strip any trailing `#` comment first, so comment text (which may contain
    // `=` or `(`) can't be mistaken for assignment or call syntax below
    // (e.g. `print(x)  # a = b` must not look like an assignment).
    let trimmed = trimSpacesAndTabs(strippingTrailingComment(from: rawTrimmed))

    // A line that was nothing but a comment is harmless at module level.
    if trimmed.isEmpty {
        return true
    }

    for prefix in ["def ", "async def ", "class ", "import ", "from ", "@"]
    where trimmed.hasPrefix(prefix) {
        return true
    }

    // Bare string literals are module-level docstrings — safe.
    if trimmed.hasPrefix("\"\"\"") || trimmed.hasPrefix("'''") || trimmed.hasPrefix("\"")
        || trimmed.hasPrefix("'")
    {
        return true
    }

    // Control-flow / side-effecting statements are quarantined. The `token + "("`
    // branch catches bare calls whose name matches a keyword while avoiding false
    // matches on names that merely share a prefix (e.g. `format` vs `for`).
    for token in [
        "assert", "raise", "return", "del", "pass", "for", "while",
        "if", "with", "try", "except", "match", "finally", "else",
        "elif", "break", "continue", "yield", "global", "nonlocal",
        "async for", "async with",
    ] {
        if trimmed == token || trimmed.hasPrefix(token + " ") || trimmed.hasPrefix(token + ":")
            || trimmed.hasPrefix(token + "(")
        {
            return false
        }
    }

    // Assignments: module level only when the RHS has no function calls. Keeps
    // module-level constants while quarantining `p = Patient(...)`-style code.
    if let rhsStart = findAssignmentRHS(in: trimmed) {
        let rhs = trimSpacesAndTabs(String(trimmed[rhsStart...]))
        return !rhsContainsFunctionCall(rhs)
    }

    return false
}

/// Removes a trailing `#` comment from a single line, leaving `#` characters
/// that appear inside string literals untouched. The scan tracks single- and
/// double-quoted string state (honouring backslash escapes) and stops at the
/// first `#` seen outside a string.
private func strippingTrailingComment(from line: String) -> String {
    var stringDelimiter: Character?
    var prev: Character = " "
    var idx = line.startIndex
    while idx < line.endIndex {
        let ch = line[idx]
        if let delim = stringDelimiter {
            if ch == delim && prev != "\\" {
                stringDelimiter = nil
            }
        } else {
            switch ch {
            case "\"", "'": stringDelimiter = ch
            case "#": return String(line[line.startIndex..<idx])
            default: break
            }
        }
        prev = ch
        idx = line.index(after: idx)
    }
    return line
}

/// Index just past the `=` of a plain or annotated assignment (`x = …`,
/// `x: T = …`, `a, b = …`). Returns nil for comparisons, walrus, augmented.
func findAssignmentRHS(in line: String) -> String.Index? {
    var depth = 0
    var prev: Character = " "
    var idx = line.startIndex
    while idx < line.endIndex {
        let ch = line[idx]
        switch ch {
        case "(", "[", "{": depth += 1
        case ")", "]", "}": depth = max(0, depth - 1)
        case "=":
            if depth == 0 {
                let nextIdx = line.index(after: idx)
                let next: Character = nextIdx < line.endIndex ? line[nextIdx] : " "
                let isComparison = prev == "!" || prev == "<" || prev == ">" || prev == "="
                let isWalrus = prev == ":"
                let isAugmented = "+-*/%|&^~".contains(prev)
                let isDoubleEq = next == "="
                if !isComparison && !isWalrus && !isAugmented && !isDoubleEq {
                    return line.index(after: idx)
                }
            }
        default: break
        }
        prev = ch
        idx = line.index(after: idx)
    }
    return nil
}

/// True if `rhs` contains an identifier immediately followed by `(`.
func rhsContainsFunctionCall(_ rhs: String) -> Bool {
    var prev: Character = " "
    for ch in rhs {
        if ch == "(" && (prev.isLetter || prev.isNumber || prev == "_" || prev == ")") {
            return true
        }
        prev = ch
    }
    return false
}

// MARK: - Stdlib-only string helpers (Foundation-free for WASM)

/// Split on "\n" keeping empty substrings (matches `components(separatedBy:)`).
private func splitLines(_ s: String) -> [String] {
    s.split(separator: "\n" as Character, omittingEmptySubsequences: false).map(String.init)
}

/// Trim leading/trailing spaces and tabs only (matches `.whitespaces`).
private func trimSpacesAndTabs(_ s: String) -> String {
    let isHWS: (Character) -> Bool = { $0 == " " || $0 == "\t" }
    return String(s.drop(while: isHWS).reversed().drop(while: isHWS).reversed())
}

/// Trim leading/trailing whitespace and newlines (matches `.whitespacesAndNewlines`).
private func trimWhitespaceAndNewlines(_ s: String) -> String {
    let isWS: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    return String(s.drop(while: isWS).reversed().drop(while: isWS).reversed())
}

private func trimmedString(_ s: String) -> String {
    trimWhitespaceAndNewlines(s)
}

/// Two-digit lowercase hex for a control-character scalar (< 0x20).
private func hex2(_ value: UInt32) -> String {
    let digits = "0123456789abcdef"
    let hi = digits[digits.index(digits.startIndex, offsetBy: Int((value >> 4) & 0xF))]
    let lo = digits[digits.index(digits.startIndex, offsetBy: Int(value & 0xF))]
    return String([hi, lo])
}
