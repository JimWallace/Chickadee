// APIServer/Utilities/IdentifierValidation.swift
//
// Tiny shared helpers for validating the identifier safety of
// instructor-authored manifest fields (pattern-family ids, case keys,
// variable names, etc.).  Lifted out of `ManifestValidation.swift` in
// v0.4.182 when that file was split into per-concern validators —
// all three (`ManifestDependencyValidator`, `PatternFamilyValidator`,
// `NotebookCheckValidator`) call these.
//
// Two questions live here and must not be collapsed into one:
// `isValidIdentifier` asks whether a BARE NAME is legal (a variable, a
// parameter), `isValidFunctionTarget` whether a CALL TARGET is. They disagree
// on Java, whose target is a qualified `Solution.classify` that is not itself
// an identifier, and on Lua, whose bare names are checked against Lua's grammar
// while its targets still borrow Python's.
//
// The per-language arms are what makes them right: a check here that answers
// with Python's rules on every assignment does not fail loudly, it simply
// refuses a name the author's language considers ordinary, in a message naming
// a language their assignment has nothing to do with.

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

/// Whether `s` is a valid *bare name* in `language` — a variable, a parameter,
/// a module-level identifier.
///
/// Distinct from `isValidFunctionTarget`, and deliberately so: the two answer
/// different questions and disagree on two languages. A Java call target is a
/// qualified `Solution.classify`, which is not a Java identifier; a Lua bare
/// name is checked against Lua's own grammar while a Lua call target still
/// borrows Python's. Collapsing them would either let a dotted name through as
/// a variable or refuse Java's only legal call target.
///
/// Lives here rather than beside its first caller because it has several: it
/// was written for notebook checks, stayed `private` in that file, and the
/// pattern-family validator went on applying Python's rules to every language's
/// parameter and variable names as a result.
func isValidIdentifier(_ value: String, language: AssignmentLanguage) -> Bool {
    switch language {
    case .python: return isValidPythonIdentifier(value)
    case .r: return isValidRIdentifier(value)
    case .lua: return isValidLuaIdentifier(value)
    case .octave: return isValidOctaveIdentifier(value)
    case .cpp: return isValidCppIdentifier(value)
    case .racket: return isValidRacketIdentifier(value)
    case .java: return isValidJavaIdentifier(value)
    }
}

/// Human-readable name of the identifier grammar, for validation messages.
func identifierKindName(_ language: AssignmentLanguage) -> String {
    switch language {
    case .python: return "Python identifier"
    case .r: return "R name"
    case .lua: return "Lua identifier"
    case .octave: return "Octave identifier"
    case .cpp: return "C++ identifier"
    case .racket: return "Racket identifier"
    case .java: return "Java identifier"
    }
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
