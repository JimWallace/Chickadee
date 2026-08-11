// APIServer/Utilities/JavaSourceHelpers.swift
//
// Java identifier grammar and comment escaping for the generated-test
// renderers — the Java sibling of `CppScriptHelpers` and `RacketScriptHelpers`.
//
// NAMED `JavaSourceHelpers`, NOT `JavaScriptHelpers`. The neighbours are
// `CppScriptHelpers` and `RacketScriptHelpers`, so the pattern would give
// "JavaScriptHelpers" — a filename naming a different language entirely, in a
// codebase that also ships JavaScript under `Public/`. Consistency is not worth
// that; a reader grepping for JavaScript helpers must not land here.

import Core
import Foundation

/// Java's reserved words, which cannot be used as identifiers.
///
/// The 50 keywords of JLS §3.9 plus the three reserved *literals* (`true`,
/// `false`, `null`), which are not keywords by the spec's own classification
/// but are equally unusable as names.
///
/// The contextual keywords (`var`, `record`, `sealed`, `permits`, `yield`,
/// `module`, `requires`, …) are deliberately ABSENT: they are legal identifiers
/// everywhere except their own syntactic position, so rejecting them would
/// refuse an instructor a perfectly compilable name. `var` in particular is a
/// plausible parameter name and compiles fine as one.
///
/// `_` alone IS reserved (Java 9 removed it as an identifier), and is caught
/// here rather than by the character rules, which would otherwise accept it.
private let javaReservedWords: Set<String> = [
    "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
    "class", "const", "continue", "default", "do", "double", "else", "enum",
    "extends", "final", "finally", "float", "for", "goto", "if", "implements",
    "import", "instanceof", "int", "interface", "long", "native", "new",
    "package", "private", "protected", "public", "return", "short", "static",
    "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
    "transient", "try", "void", "volatile", "while",
    "true", "false", "null",
    "_",
]

/// Whether `name` is a Java identifier Chickadee will generate code around.
///
/// ASCII-only, deliberately, and for C++'s reason rather than Java's: the
/// language itself admits any character `Character.isJavaIdentifierStart`
/// accepts, which is most of Unicode. Generated identifiers are pasted into
/// source that also carries shell heredocs and JSON, so the narrow rule is the
/// one whose escaping is knowable. An instructor who wants a non-ASCII display
/// name has `displayName` for it.
///
/// `$` is accepted by javac and rejected here on purpose: it is legal but
/// conventionally reserved for compiler-generated names, and a `$` in a
/// generated test would read as machinery rather than as the author's.
func isValidJavaIdentifier(_ name: String) -> Bool {
    guard !name.isEmpty, !javaReservedWords.contains(name) else { return false }
    let scalars = Array(name.unicodeScalars)
    let isLetter: (Unicode.Scalar) -> Bool = {
        ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || $0 == "_"
    }
    guard isLetter(scalars[0]) else { return false }
    return scalars.dropFirst().allSatisfy { isLetter($0) || ($0 >= "0" && $0 <= "9") }
}

/// Whether `name` is a qualified `Class.method` reference of the shape a Java
/// pattern family's `function` field must carry, and its two halves.
///
/// WHY JAVA IS THE ONE LANGUAGE THAT NEEDS THIS. Every other language here can
/// call a bare function name; Java has no free functions, and a public class
/// must live in a file of its own name — so the class the student's method
/// lives in is decided by what they upload, and a generated test has to say it
/// out loud. Guessing it is exactly the silent-wrong-answer shape this codebase
/// keeps paying for, so a bare name is REFUSED at save time with a message that
/// says what to write instead.
///
/// Only one dot is accepted: `Outer.Inner.method` would name a nested class,
/// which an intro submission does not produce and which would make the refusal
/// message ambiguous.
func javaQualifiedFunction(_ name: String) -> (className: String, methodName: String)? {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let className = String(parts[0])
    let methodName = String(parts[1])
    guard isValidJavaIdentifier(className), isValidJavaIdentifier(methodName) else { return nil }
    return (className, methodName)
}

/// A single-line `//` comment carrying `text`, with newlines stripped so a
/// multi-line value cannot break out of the comment and become code.
func javaComment(_ text: String) -> String {
    "// " + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
}

/// A Java class name derived from a generated test's filename stem.
///
/// Generated stems look like `publictest_bmi_01`, which is already a legal Java
/// identifier — but the class in a generated test does NOT have to match its
/// filename, because the file is a `.sh` wrapper and the Java source inside it
/// is written to a fixed name. So this exists for the one thing that does need
/// care: a stem that is a Java reserved word, or that starts with a digit,
/// would produce a class declaration that does not compile.
///
/// The prefix is unconditional rather than applied only when needed: a
/// conditional would make the generated class name depend on the family id in a
/// way nobody could predict from reading a test, and these names are never seen
/// by a student.
func javaGeneratedClassName(forStem stem: String) -> String {
    let cleaned = String(
        stem.unicodeScalars.map { scalar -> Character in
            let ok =
                (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
            return ok ? Character(scalar) : "_"
        })
    return "CkTest_" + cleaned
}
