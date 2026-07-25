// APIServer/Utilities/IdentifierValidation.swift
//
// Tiny shared helpers for validating Python-identifier safety of
// instructor-authored manifest fields (pattern-family ids, case keys,
// variable names, etc.).  Lifted out of `ManifestValidation.swift` in
// v0.4.182 when that file was split into per-concern validators —
// all three (`ManifestDependencyValidator`, `PatternFamilyValidator`,
// `NotebookCheckValidator`) call these.

import Foundation

let pythonKeywords: Set<String> = [
    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
    "class", "continue", "def", "del", "elif", "else", "except", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
]

func isValidPythonIdentifier(_ s: String) -> Bool {
    guard !s.isEmpty, !pythonKeywords.contains(s) else { return false }
    let chars = Array(s)
    let first = chars[0]
    guard first.isLetter || first == "_" else { return false }
    for ch in chars.dropFirst() {
        guard ch.isLetter || ch.isNumber || ch == "_" else { return false }
    }
    return true
}

/// R reserved words (`?Reserved`), which are not syntactic names.
let rReservedWords: Set<String> = [
    "if", "else", "repeat", "while", "function", "for", "in", "next", "break",
    "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "NA_integer_", "NA_real_",
    "NA_complex_", "NA_character_",
]

/// Whether `s` is a syntactically valid R name — the R analogue of
/// `isValidPythonIdentifier`, so an idiomatic name like `my.df` is accepted on
/// an R assignment instead of being rejected against Python's rules.
///
/// R names may start with a letter or a dot and may contain letters, digits,
/// `.` and `_`. Two differences from Python: a leading underscore is *not*
/// allowed, and a name beginning with a dot followed by a digit (e.g. `.2x`) is
/// reserved by R and is not a syntactic name. Reserved words are excluded.
func isValidRIdentifier(_ s: String) -> Bool {
    guard !s.isEmpty, !rReservedWords.contains(s) else { return false }
    let chars = Array(s)
    let first = chars[0]
    guard first.isLetter || first == "." else { return false }
    if first == ".", chars.count > 1, chars[1].isNumber { return false }
    for ch in chars.dropFirst() {
        guard ch.isLetter || ch.isNumber || ch == "." || ch == "_" else { return false }
    }
    return true
}

/// Stricter than Python identifier: lowercase-preferred alphanumeric +
/// underscore, allowed to start with a digit (for case keys like "01").
/// Used to validate filename-fragment safety for generated test scripts.
func isValidIdentifierFragment(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}
