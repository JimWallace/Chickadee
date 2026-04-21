import Foundation

struct NotebookExtraction {
    let source: String
    let codeCellCount: Int
}

struct NotebookExtractor {
    func notebookJSONObject(from data: Data, filename: String) throws -> [String: Any] {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        guard let object = rawObject as? [String: Any] else {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        return object
    }

    func isNotebookJSONObject(_ notebook: [String: Any]) -> Bool {
        guard notebook["metadata"] != nil,
              notebook["nbformat"] != nil,
              notebook["cells"] is [[String: Any]] || notebook["cells"] is [Any] else {
            return false
        }
        return true
    }

    func extractPythonSource(from notebook: [String: Any], filename: String) throws -> NotebookExtraction {
        guard let cells = notebook["cells"] as? [[String: Any]] else {
            throw SubmissionNormalizationError.invalidPythonSubmission(filename)
        }

        var parts: [String] = []
        var codeCellCount = 0

        for (index, cell) in cells.enumerated() {
            guard cell["cell_type"] as? String == "code" else { continue }

            let rawSource: String
            if let sourceLines = cell["source"] as? [String] {
                rawSource = sourceLines.joined()
            } else if let sourceString = cell["source"] as? String {
                rawSource = sourceString
            } else {
                continue
            }

            let trimmedSource = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty else { continue }

            let cellSource = sanitizeCellForModule(trimmedSource)
            guard !cellSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            codeCellCount += 1
            parts.append("# --- cell \(index + 1) ---\n\(cellSource)")
        }

        guard !parts.isEmpty else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }

        return NotebookExtraction(
            source: "# Generated from \(filename)\n\n" + parts.joined(separator: "\n\n") + "\n",
            codeCellCount: codeCellCount
        )
    }

    // Sanitizes a single notebook code cell for use as a module-level Python
    // source block:
    //
    //   • IPython magic commands (lines beginning with %) and shell pass-through
    //     commands (lines beginning with !) are stripped — they are never valid
    //     Python outside a Jupyter kernel.
    //
    //   • Top-level statements are classified as either *safe* (definitions,
    //     imports, constants, and other side-effect-free declarations) or
    //     *quarantined* (executable statements that could crash or produce
    //     side-effects at import time).
    //
    //   • Safe code is emitted at module level so functions, classes, and
    //     module-level constants remain accessible to the test runner.
    //
    //   • Quarantined code is wrapped in `if __name__ == "__main__":` so it
    //     does not execute when the file is imported as a module, but remains
    //     visible in the generated file for debugging.
    //
    //   • Bracket depth is tracked across lines so that continuation lines of
    //     a multi-line statement (e.g. the elements of a list literal whose
    //     closing `]` sits at column 0) are not re-classified as new statements.
    //
    // Example input cell:
    //
    //   BMI_UNDERWEIGHT_MAX: float = 18.5
    //
    //   assert BMI_UNDERWEIGHT_MAX > 0
    //
    //   def bmi_category(b: float) -> str:
    //       if b < BMI_UNDERWEIGHT_MAX:
    //           return "underweight"
    //
    //   print(bmi_category(22.0))
    //
    // Output:
    //
    //   BMI_UNDERWEIGHT_MAX: float = 18.5
    //
    //   def bmi_category(b: float) -> str:
    //       if b < BMI_UNDERWEIGHT_MAX:
    //           return "underweight"
    //
    //   if __name__ == "__main__":
    //       assert BMI_UNDERWEIGHT_MAX > 0
    //       print(bmi_category(22.0))
    //
    func sanitizeCellForModule(_ source: String) -> String {
        // Strip magic/shell lines first.
        let lines = source.components(separatedBy: "\n").filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return !s.hasPrefix("%") && !s.hasPrefix("!")
        }

        // Walk line-by-line, routing each line to the safe or quarantine bucket.
        // A top-level (non-indented, non-empty) line sets the current block kind;
        // subsequent indented lines (the block body) inherit that kind.
        // Bracket depth prevents flush-left continuation lines (e.g. a bare `]`)
        // from being mistaken for new top-level statements.
        var defLines:   [String] = []
        var usageLines: [String] = []
        var inUsage = false
        var bracketDepth = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only treat as a new top-level statement if we are not inside open brackets.
            let isTopLevel = bracketDepth == 0 && !line.isEmpty && !(line.first?.isWhitespace ?? true)

            // Update depth *after* the isTopLevel check — depth reflects prior lines.
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

        let defBlock = defLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !defBlock.isEmpty {
            parts.append(defBlock)
        }

        let usageBlock = usageLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !usageBlock.isEmpty {
            let indented = usageBlock
                .components(separatedBy: "\n")
                .map { "    " + $0 }
                .joined(separator: "\n")
            parts.append("if __name__ == \"__main__\":\n\(indented)")
        }

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Top-level statement classification helpers

/// Returns true if a non-indented Python statement is safe to emit at module
/// level — i.e. it defines something (function, class, import, constant) rather
/// than executing side-effectful or control-flow code.
private func isSafeTopLevelStatement(_ trimmed: String) -> Bool {
    // Definitions and structural annotations are always safe.
    for prefix in ["def ", "async def ", "class ", "import ", "from ", "@", "#"] {
        if trimmed.hasPrefix(prefix) { return true }
    }

    // Bare string literals are module-level docstrings — safe.
    if trimmed.hasPrefix("\"\"\"") || trimmed.hasPrefix("'''") ||
       trimmed.hasPrefix("\"")     || trimmed.hasPrefix("'") {
        return true
    }

    // Control-flow, side-effecting, and other executable statements are quarantined.
    // The `token + "("` branch catches bare calls whose name matches a keyword
    // (e.g. `match(...)` in older code), while preventing false matches on names
    // that merely share a prefix (e.g. `format` vs `for`).
    for token in ["assert", "raise", "return", "del", "pass", "for", "while",
                  "if", "with", "try", "except", "match", "finally", "else",
                  "elif", "break", "continue", "yield", "global", "nonlocal",
                  "async for", "async with"] {
        if trimmed == token ||
           trimmed.hasPrefix(token + " ") ||
           trimmed.hasPrefix(token + ":") ||
           trimmed.hasPrefix(token + "(") {
            return false
        }
    }

    // Assignments: emit at module level only when the RHS is free of function calls.
    // This keeps module-level constants (simple literals, arithmetic, tuples, lists)
    // while quarantining constructions like `patient0 = Patient(name="Alice")` that
    // execute code and may fail at import time.
    if let rhsStart = findAssignmentRHS(in: trimmed) {
        let rhs = String(trimmed[rhsStart...]).trimmingCharacters(in: .whitespaces)
        return !rhsContainsFunctionCall(rhs)
    }

    // Bare expression or unrecognised statement — quarantine to be safe.
    return false
}

/// Returns the index just past the `=` of a plain or annotated assignment
/// (`x = …`, `x: T = …`, `a, b = …`).
/// Returns nil for comparisons (`==`, `!=`, `<=`, `>=`), walrus (`:=`), and
/// augmented assignments (`+=`, `-=`, `*=`, …).
private func findAssignmentRHS(in line: String) -> String.Index? {
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
                let isWalrus     = prev == ":"
                let isAugmented  = "+-*/%|&^~".contains(prev)
                let isDoubleEq   = next == "="
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

/// Returns true if `rhs` contains an identifier immediately followed by `(`,
/// which indicates a function or method call.
private func rhsContainsFunctionCall(_ rhs: String) -> Bool {
    var prev: Character = " "
    for ch in rhs {
        if ch == "(" && (prev.isLetter || prev.isNumber || prev == "_" || prev == ")") {
            return true
        }
        prev = ch
    }
    return false
}

// MARK: - Notebook-to-code extraction for test setup directories

/// Extract code cells from all .ipynb notebooks in `directory` into .py or .R source files.
///
/// This replaces the former runner-support/Makefile prep step with a pure-Swift
/// implementation. The .ipynb format is plain JSON — no `make`, Python, or external
/// tools are required. Kernel language detection mirrors the logic in
/// TestSetupRoutes.normalizeNotebookForJupyterLite() and browser-runner.js.
///
/// Module-level (not private) so WorkerTests can exercise it directly.
func extractNotebooksToCode(in directory: URL) throws {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []

    for item in items where item.pathExtension.lowercased() == "ipynb" {
        // Every .ipynb in the directory is extracted to .py (or .R).  The
        // starter template notebook is already removed by process() before
        // this function runs (driven by manifest.starterNotebook), so the
        // only notebooks remaining are the student/canonical submission and
        // any instructor-provided helper notebooks that should be converted.
        guard
            let data     = try? Data(contentsOf: item),
            let notebook = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells    = notebook["cells"] as? [[String: Any]]
        else { continue }

        // Detect kernel language: ir/r/webr → R, everything else → Python.
        let language: String = {
            if let meta = notebook["metadata"] as? [String: Any] {
                if let ks = meta["kernelspec"] as? [String: Any],
                   let name = (ks["name"] as? String)?.lowercased() {
                    if name == "ir" || name == "r" || name == "webr" { return "r" }
                }
                if let li = meta["language_info"] as? [String: Any],
                   (li["name"] as? String)?.lowercased() == "r" { return "r" }
            }
            return "python"
        }()

        let ext    = language == "r" ? "R" : "py"
        let stem   = item.deletingPathExtension().lastPathComponent
        let outURL = directory.appendingPathComponent("\(stem).\(ext)")

        var output = "# Generated from \(item.lastPathComponent)\n\n"
        let extractor = NotebookExtractor()
        for cell in cells {
            guard cell["cell_type"] as? String == "code" else { continue }
            let raw: String
            if let arr = cell["source"] as? [String] {
                raw = arr.joined()
            } else if let str = cell["source"] as? String {
                raw = str
            } else { continue }

            var src = raw
            while src.last?.isWhitespace == true { src.removeLast() }
            guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if language == "python" {
                let cellSource = extractor.sanitizeCellForModule(src)
                guard !cellSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                output += cellSource + "\n\n"
            } else {
                output += src + "\n\n"
            }
        }

        try output.write(to: outURL, atomically: true, encoding: .utf8)
    }
}
