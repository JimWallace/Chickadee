// RunnerCore notebook extraction — the single source of truth for turning a
// Jupyter notebook's code cells into runnable Python.
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

public enum NotebookLanguage: String, Sendable, Equatable {
    case python
    case r
}

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
    var bracketDepth = 0

    for line in lines {
        let trimmed = trimSpacesAndTabs(line)
        // Only a new top-level statement when not inside open brackets.
        let isTopLevel = bracketDepth == 0 && !line.isEmpty && !(line.first?.isWhitespace ?? true)

        // Update depth AFTER the isTopLevel check — depth reflects prior lines.
        for ch in line {
            switch ch {
            case "(", "[", "{": bracketDepth += 1
            case ")", "]", "}": bracketDepth = max(0, bracketDepth - 1)
            default: break
            }
        }

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
    if body.contains("from __future__") {
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

// MARK: - Top-level statement classification

/// True if a non-indented Python statement is safe at module level — it defines
/// something (function, class, import, constant) rather than executing
/// side-effectful or control-flow code.
func isSafeTopLevelStatement(_ trimmed: String) -> Bool {
    for prefix in ["def ", "async def ", "class ", "import ", "from ", "@", "#"]
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
    s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
