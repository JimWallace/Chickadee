// APIServer/Services/PythonImportScanner.swift
//
// Extracts the top-level module names a Python source file imports
// unconditionally, so an authoring write can be checked against what the
// browser grading environment actually provides (see KernelEnvironment).
//
// Deliberately a scanner, not a parser. The question is narrow — "which
// third-party packages does this file require in order to be importable at all"
// — and the cost of getting it wrong is asymmetric: a missed import means the
// old status quo (an ImportError at grade time), while a wrongly-reported one
// blocks an instructor from saving legitimate work. So every ambiguity resolves
// toward reporting less.
//
// What that means concretely:
//
//   * Only column-0 statements count. An import inside a function, a class, an
//     `if`, or a `try/except ImportError` is indented by definition, so the
//     whole "do not reject what is guarded" requirement falls out of the
//     indentation rule rather than needing conditional analysis.
//   * Relative imports (`from . import x`, `from ..pkg import y`) name nothing
//     external and are skipped.
//   * `import a.b.c` requires `a`; the submodule is that package's problem.
//   * Text inside triple-quoted strings is skipped, so a docstring showing
//     example code does not register as a dependency. This matters more than it
//     sounds: teaching material quotes imports constantly.
//
// Not handled, knowingly: backslash line continuations before the module name,
// and `importlib.import_module("scipy")`. Both are rare in test scripts and
// both fail toward silence.

import Foundation

/// A top-level module name imported by a Python source file, with the line it
/// was found on (1-based) so an error can point at it.
struct PythonImport: Equatable, Sendable {
    let module: String
    let line: Int
}

enum PythonImportScanner {

    /// The distinct top-level module names `source` imports unconditionally, in
    /// first-appearance order.
    static func topLevelImports(in source: String) -> [PythonImport] {
        var found: [PythonImport] = []
        var seen: Set<String> = []
        var openDelimiter: String?

        for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let line = String(rawLine)
            let (code, delimiterAfter) = stripStringsAndComments(line, openDelimiter: openDelimiter)
            openDelimiter = delimiterAfter
            guard let statement = columnZeroStatement(in: code) else { continue }
            for module in modules(importedBy: statement) where !seen.contains(module) {
                seen.insert(module)
                found.append(PythonImport(module: module, line: index + 1))
            }
        }
        return found
    }

    // MARK: - Line preparation

    /// Returns the part of `line` that is executable code, plus the triple-quote
    /// delimiter still open at the end of it (nil when none is).
    ///
    /// Only triple-quoted strings need to carry state across lines; a
    /// single-quoted string cannot span one without a continuation. Both kinds
    /// are blanked out so a `#` or the word `import` inside a string is inert.
    private static func stripStringsAndComments(
        _ line: String,
        openDelimiter: String?
    ) -> (code: String, openDelimiter: String?) {
        var code = ""
        var open = openDelimiter
        var rest = Substring(line)

        while !rest.isEmpty {
            if let delimiter = open {
                // Inside a multi-line string: everything up to the closing
                // delimiter is not code.
                if let close = rest.range(of: delimiter) {
                    rest = rest[close.upperBound...]
                    open = nil
                    continue
                }
                return (code, open)
            }
            let character = rest[rest.startIndex]
            if character == "#" {
                return (code, nil)
            }
            if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") {
                let delimiter = String(rest.prefix(3))
                rest = rest.dropFirst(3)
                if let close = rest.range(of: delimiter) {
                    rest = rest[close.upperBound...]
                } else {
                    open = delimiter
                    rest = rest[rest.endIndex...]
                }
                continue
            }
            if character == "\"" || character == "'" {
                let quote = character
                rest = rest.dropFirst()
                while let next = rest.first {
                    rest = rest.dropFirst()
                    if next == "\\" {
                        rest = rest.dropFirst()
                    } else if next == quote {
                        break
                    }
                }
                continue
            }
            code.append(character)
            rest = rest.dropFirst()
        }
        return (code, open)
    }

    /// `code` when it is a statement at column 0, else nil.
    private static func columnZeroStatement(in code: String) -> String? {
        guard let first = code.first, !first.isWhitespace else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Statement parsing

    private static func modules(importedBy statement: String) -> [String] {
        // A line can carry several statements: `import os; import sys`.
        statement.split(separator: ";").flatMap { modules(importedBySingle: String($0)) }
    }

    private static func modules(importedBySingle statement: String) -> [String] {
        let trimmed = statement.trimmingCharacters(in: .whitespaces)
        if let rest = afterKeyword("from", in: trimmed) {
            // `from . import x` and `from ..pkg import y` are relative: local by
            // construction, nothing to check.
            guard !rest.hasPrefix(".") else { return [] }
            guard let name = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
                return []
            }
            return [topLevel(of: String(name))].compactMap { $0 }
        }
        if let rest = afterKeyword("import", in: trimmed) {
            // `import a.b as ab, c` — split on commas, take each name's head,
            // and drop any `as` alias.
            return rest.split(separator: ",").compactMap { clause in
                guard
                    let name = clause.trimmingCharacters(in: .whitespaces)
                        .split(whereSeparator: { $0 == " " || $0 == "\t" }).first
                else { return nil }
                return topLevel(of: String(name))
            }
        }
        return []
    }

    /// The remainder of `statement` after a leading `keyword`, or nil when the
    /// statement does not start with it as a whole word (so `imported = 1` and
    /// `fromage()` are not mistaken for imports).
    private static func afterKeyword(_ keyword: String, in statement: String) -> String? {
        guard statement.hasPrefix(keyword) else { return nil }
        let rest = statement.dropFirst(keyword.count)
        guard let next = rest.first, next == " " || next == "\t" else { return nil }
        let remainder = rest.trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? nil : remainder
    }

    /// `numpy.linalg` → `numpy`; nil when the result is not a plausible name.
    private static func topLevel(of dotted: String) -> String? {
        guard let head = dotted.split(separator: ".").first else { return nil }
        let name = String(head)
        guard !name.isEmpty, let first = name.first, first == "_" || first.isLetter else {
            return nil
        }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } ? name : nil
    }
}
