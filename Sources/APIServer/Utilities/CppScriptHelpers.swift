// APIServer/Utilities/CppScriptHelpers.swift
//
// Small C++ source-generation helpers shared by the pattern-family renderer
// and validators — the C++ sibling of OctaveScriptHelpers.

import Core
import Foundation

/// C++'s reserved words — an identifier cannot be one. The set is C++20's
/// keyword list plus the alternative operator spellings; module-related
/// context-sensitive words (`module`, `import`) are included because a
/// generated file that names a variable `import` invites trouble even where
/// the grammar technically allows it.
private let cppReservedWords: Set<String> = [
    "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor",
    "bool", "break", "case", "catch", "char", "char8_t", "char16_t",
    "char32_t", "class", "compl", "concept", "const", "consteval",
    "constexpr", "constinit", "const_cast", "continue", "co_await",
    "co_return", "co_yield", "decltype", "default", "delete", "do", "double",
    "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false",
    "float", "for", "friend", "goto", "if", "import", "inline", "int",
    "long", "module", "mutable", "namespace", "new", "noexcept", "not",
    "not_eq", "nullptr", "operator", "or", "or_eq", "private", "protected",
    "public", "register", "reinterpret_cast", "requires", "return", "short",
    "signed", "sizeof", "static", "static_assert", "static_cast", "struct",
    "switch", "template", "this", "thread_local", "throw", "true", "try",
    "typedef", "typeid", "typename", "union", "unsigned", "using", "virtual",
    "void", "volatile", "wchar_t", "while", "xor", "xor_eq",
]

/// True when `name` is a valid C++ identifier: letter or underscore first,
/// then letters/digits/underscores, and not a reserved word. Deliberately
/// ASCII-only — C++ formally allows Unicode identifiers, but a generated
/// test should never depend on how a toolchain handles them.
func isValidCppIdentifier(_ name: String) -> Bool {
    guard let first = name.first, first == "_" || first.isASCII && first.isLetter else {
        return false
    }
    guard
        name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
    else { return false }
    return !cppReservedWords.contains(name)
}

/// `name` if it is usable as a C++ identifier; nil otherwise. Callers refuse
/// at save time with a message naming the field — never silently rewrite.
func cppIdentifier(_ name: String) -> String? {
    isValidCppIdentifier(name) ? name : nil
}

/// A `//` comment line with newlines stripped, so authored text (labels,
/// hints) cannot break out of comment position in generated source.
func cppComment(_ text: String) -> String {
    "// " + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
}

/// Escapes `s` for embedding inside a C++ double-quoted string literal.
///
/// The C++ sibling of `escapeForPythonStringLiteral`, and it exists for the
/// same reason: an authored value reaches generated source as text, and every
/// other language escaped it while C++ and Java interpolated it raw. An
/// instructor writing an `expected` of `must be "positive"` produced
/// `"must be "positive""` — a compile error that failed the whole family with
/// no indication which case was at fault.
///
/// Control characters use THREE-DIGIT OCTAL rather than `\xHH`: a hex escape in
/// C++ has no length limit, so `\x1` followed by a literal `f` would be read as
/// the single character `\x1f` rather than as two.
func escapeForCppStringLiteral(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 || ch.value == 0x7F {
                out += String(format: "\\%03o", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}

/// A POSIX-shell single-quoted literal — for the generated `.sh` wrappers'
/// few interpolated values (filenames derive from validated identifiers, but
/// quoting anyway keeps the wrapper safe by construction).
func shellSingleQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
