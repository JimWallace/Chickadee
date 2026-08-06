// APIServer/Services/RLibraryScanner.swift
//
// Extracts the R packages a script requires, so an authoring write can be
// checked against what the browser grading kernel actually provides — the R
// counterpart to PythonImportScanner.
//
// The same asymmetry applies and drives every decision here: a missed reference
// leaves the old status quo (a grade-time failure), while a wrongly-reported one
// blocks an instructor from saving legitimate work. So ambiguity resolves toward
// reporting less.
//
// R names a package in two ways, and they need DIFFERENT rules:
//
//   * `library(dplyr)` / `require(dplyr)` — attach the package. Counted only at
//     column 0, exactly as Python imports are: a `library()` inside a function
//     or an `if (interactive())` is indented by definition, so "do not reject
//     what is guarded" falls out of the indentation rule rather than needing
//     conditional analysis.
//
//   * `dplyr::filter(...)` — a qualified reference. Counted ANYWHERE, including
//     inside function bodies. Not an inconsistency: `::` is not a conditional
//     construct. It is the idiomatic way to use a package without attaching it,
//     it appears overwhelmingly inside functions, and a column-0-only rule would
//     miss almost every real use.
//
// Both forms are read out of DIFFERENTLY prepared text, which is the one subtle
// thing here. Strings must be blanked before looking for `::` and for
// `library(dplyr)`, or prose like `"use dplyr::filter"` in a hint registers as a
// dependency. But `library("dplyr")` keeps its package name *inside* a string,
// so blanking would erase it. So the quoted form is matched on
// comments-stripped-only text, with a pattern that requires the quote to sit
// immediately inside the parentheses — which `"run library(dplyr) first"` does
// not satisfy, because there is no quote after the paren.
//
// `requireNamespace("pkg")` is read too: it is the documented way to *test* for
// a package, but the name still identifies a hard dependency of the branch that
// follows.
//
// Not handled, knowingly: `do.call("library", ...)`, a name built at run time,
// and `loadNamespace()` behind a variable. All are rare in test scripts and all
// fail toward silence.

import Foundation

/// A package reference found in R source, with the line it was found on
/// (1-based) so an error can point at it.
struct RLibraryReference: Equatable, Sendable {
    let package: String
    let line: Int
}

enum RLibraryScanner {

    /// The distinct package names `source` requires, in first-appearance order.
    static func referencedPackages(in source: String) -> [RLibraryReference] {
        var found: [RLibraryReference] = []
        var seen: Set<String> = []

        for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let withoutComments = stripComments(String(rawLine))
            let code = blankStrings(withoutComments)
            var names: [String] = []

            // Qualified references: anywhere on the line, strings blanked.
            names += captures(of: Self.qualifiedPattern, in: code, group: 1)

            // Attachments: column 0 only. `code` is used for the unquoted form
            // and `withoutComments` for the quoted one — see the header.
            if let first = code.first, !first.isWhitespace {
                names += captures(of: Self.attachUnquotedPattern, in: code, group: 2)
                names += captures(of: Self.attachQuotedPattern, in: withoutComments, group: 3)
            }

            for name in names where !seen.contains(name) {
                seen.insert(name)
                found.append(RLibraryReference(package: name, line: index + 1))
            }
        }
        return found
    }

    // MARK: - Line preparation

    /// Everything before an unquoted `#`. R comments run to end of line, and a
    /// `#` inside a string is not a comment.
    private static func stripComments(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        var quote: Character?
        while let character = rest.first {
            if let open = quote {
                out.append(character)
                rest = rest.dropFirst()
                if character == "\\" {
                    if let escaped = rest.first {
                        out.append(escaped)
                        rest = rest.dropFirst()
                    }
                } else if character == open {
                    quote = nil
                }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" { quote = character }
            out.append(character)
            rest = rest.dropFirst()
        }
        return out
    }

    /// Replaces every string literal's contents with spaces, preserving the
    /// quotes so token boundaries survive.
    private static func blankStrings(_ code: String) -> String {
        var out = ""
        var rest = Substring(code)
        while let character = rest.first {
            guard character == "\"" || character == "'" else {
                out.append(character)
                rest = rest.dropFirst()
                continue
            }
            let quote = character
            out.append(quote)
            rest = rest.dropFirst()
            while let next = rest.first {
                rest = rest.dropFirst()
                if next == "\\" {
                    if !rest.isEmpty { rest = rest.dropFirst() }
                    out.append(" ")
                    out.append(" ")
                } else if next == quote {
                    out.append(quote)
                    break
                } else {
                    out.append(" ")
                }
            }
        }
        return out
    }

    // MARK: - Matching

    private static func captures(
        of regex: NSRegularExpression?, in text: String, group: Int
    ) -> [String] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard
                match.numberOfRanges > group,
                let captured = Range(match.range(at: group), in: text)
            else { continue }
            let name = String(text[captured])
            if isPlausiblePackageName(name) { found.append(name) }
        }
        return found
    }

    /// R package names are letters, digits and dots, and start with a letter —
    /// an underscore is not legal (CRAN policy, and `library()` would fail on
    /// one anyway).
    ///
    /// The patterns below deliberately MATCH underscores so this can reject the
    /// whole token. Excluding `_` from the pattern instead would truncate
    /// `library(test_runtime)` to `test` and report that — inventing a
    /// dependency on a package nobody named, which is the one failure mode this
    /// scanner must not have. Rejecting outright yields silence instead.
    private static func isPlausiblePackageName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." }
    }

    /// `dplyr::filter` / `dplyr:::internal`.
    private static let qualifiedPattern = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9._]*)\s*:::?\s*[A-Za-z._]"#)

    /// `library(dplyr)` — unquoted symbol.
    private static let attachUnquotedPattern = try? NSRegularExpression(
        pattern: #"\b(library|require|requireNamespace)\s*\(\s*([A-Za-z][A-Za-z0-9._]*)"#)

    /// `library("dplyr")` — the quote must sit immediately inside the paren, so
    /// prose mentioning a call does not match.
    private static let attachQuotedPattern = try? NSRegularExpression(
        pattern: #"\b(library|require|requireNamespace)\s*\(\s*(["'])([A-Za-z][A-Za-z0-9._]*)\2"#)
}
