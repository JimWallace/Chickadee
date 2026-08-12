// APIServer/Utilities/IdentifierValidation.swift
//
// Tiny shared helpers for validating Python-identifier safety of
// instructor-authored manifest fields (pattern-family ids, case keys,
// variable names, etc.).  Lifted out of `ManifestValidation.swift` in
// v0.4.182 when that file was split into per-concern validators —
// all three (`ManifestDependencyValidator`, `PatternFamilyValidator`,
// `NotebookCheckValidator`) call these.

import Core
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

/// Whether `s` is a usable pattern-family function target in `language`.
///
/// This dispatch exists because the check it replaced was language-BLIND: a
/// family's `functionName` was validated against Python's identifier rules on
/// every assignment, which made two languages unauthorable outright. Java has
/// no free functions, so its target is a qualified `Class.method` — and the dot
/// fails Python's rules. Racket's idiomatic `bmi-category` fails them on the
/// hyphen.
///
/// It stayed invisible because both renderers were written believing this check
/// was already language-aware, so neither shouts: the Java renderer calls its
/// unqualified branch "unreachable through authoring", and the Racket renderer
/// quietly sanitizes an invalid name to `ck-invalid-name`. Nothing failed
/// loudly; the family simply could not be saved, with a message naming Python
/// on an assignment that has nothing to do with Python.
///
/// Each arm delegates to the grammar that language's RENDERER already uses, so
/// what validation accepts and what rendering can emit cannot drift apart.
///
/// Only Lua still borrows Python's rule, because Lua has a sanitizer
/// (`luaIdentifier`) rather than a validator and the two grammars agree on
/// every name an author can realistically type. C++, Octave, Java and Racket
/// each answer with their own — which matters: those four reject their
/// language's RESERVED WORDS, so a family targeting `class` on a C++ assignment
/// is refused at save instead of rendering a test that cannot compile.
func isValidFunctionTarget(_ s: String, language: AssignmentLanguage) -> Bool {
    switch language {
    case .python, .lua:
        return isValidPythonIdentifier(s)
    case .r:
        return isValidRIdentifier(s)
    case .cpp:
        return isValidCppIdentifier(s)
    case .octave:
        return isValidOctaveIdentifier(s)
    case .racket:
        return isValidRacketIdentifier(s)
    case .java:
        return javaQualifiedFunction(s) != nil
    }
}

/// What a valid target looks like in `language`, for the save-time refusal.
/// Only the two languages with a non-obvious rule say more than their name.
func functionTargetExpectation(for language: AssignmentLanguage) -> String {
    switch language {
    case .java:
        return "a qualified Class.method name, e.g. `Solution.classify`"
    case .racket:
        return "a Racket identifier, e.g. `bmi-category`"
    case .python, .r, .lua, .octave, .cpp:
        return "a valid \(language.displayName) identifier"
    }
}

/// Stricter than Python identifier: lowercase-preferred alphanumeric +
/// underscore, allowed to start with a digit (for case keys like "01").
/// Used to validate filename-fragment safety for generated test scripts.
func isValidIdentifierFragment(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}
