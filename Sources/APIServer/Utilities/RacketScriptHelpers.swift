// APIServer/Utilities/RacketScriptHelpers.swift
//
// Racket-side helpers for generated scripts: the identifier grammar.
// (Submission module loading lives in the runtime itself —
// Tools/runner-support/test_runtime.rkt builds the `(file …)` path.)

import Foundation

/// Characters that end an identifier in Racket's reader. Everything else is
/// fair game — `set!`, `list->vector`, `char<=?`, `+` and `1+` are all legal
/// names — which is why this is a denylist rather than the alphanumeric
/// allowlist the other five languages use.
private let racketDelimiters: Set<Character> = [
    "(", ")", "[", "]", "{", "}", "\"", ",", "'", "`", ";", "|", "\\",
]

/// Whether `name` is a legal Racket identifier.
///
/// Deliberately permissive, because Racket is: rejecting `bmi-category` or
/// `valid?` would refuse the names a CS 135 student is taught to write, and
/// hyphenated names are the house style throughout the HtDP curriculum. The
/// three things actually excluded are the ones that would misparse:
///
///   * anything containing a reader delimiter or whitespace — it would end the
///     identifier early and turn the rest into stray source;
///   * a name the reader would take as a NUMBER (`42`, `-1.5`, `+inf.0`), which
///     cannot be a variable;
///   * a leading `#`, which begins a reader macro (`#t`, `#lang`, `#(`).
func isValidRacketIdentifier(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    guard !name.hasPrefix("#") else { return false }
    for character in name {
        if character.isWhitespace || racketDelimiters.contains(character) { return false }
    }
    // `Double(_:)` accepts "42", "-1.5", "1e3" and "inf"/"nan" spellings, which
    // is the same set the reader would claim. A name it parses is a number, not
    // an identifier.
    if Double(name) != nil { return false }
    if name == "+inf.0" || name == "-inf.0" || name == "+nan.0" || name == "-nan.0" {
        return false
    }
    return true
}
