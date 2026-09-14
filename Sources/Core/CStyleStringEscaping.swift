// Core/CStyleStringEscaping.swift
//
// One string escaper for every language whose literals take C-style escapes.
//
// Seven languages render a `JSONValue` string (`JSONValue.swift` and its
// per-language siblings) and three of them also escape authored text into
// generated test sources (`PythonScriptHelpers`, `CppScriptHelpers`,
// `JavaSourceHelpers`). Every one of those escapers had the same twenty
// lines: double the backslash, escape the quote, spell newline / carriage
// return / tab by name, and fall back to a numeric escape for the remaining
// control characters. Only that fallback differs — and the difference is a
// measured trap in three languages, so it is stated per preset rather than
// re-derived by each copy.
//
// Output bytes are content-addressed: generated scripts embed a `spec_hash`
// that feeds `TestSetupCache` invalidation, so a change to any preset shifts
// every generated script's hash. The presets reproduce the previous per-copy
// output exactly.

import Foundation

/// How to escape a string for a double-quoted literal in one language.
public struct CStyleStringEscaping: Sendable, Equatable {
    /// The spelling used for a control character that has no named escape.
    public enum ControlCharacterForm: Sendable, Equatable {
        /// Two hex digits, `\x1f`.
        case hexTwoDigit
        /// A backslash-u escape with four lowercase hex digits.
        case unicodeFourDigitLowercase
        /// A backslash-u escape with four uppercase hex digits.
        case unicodeFourDigitUppercase
        /// Exactly three octal digits, `\037`. Stops at three digits by rule,
        /// where `\x` in the same languages consumes every hex digit that
        /// follows and swallows payload.
        case octalThreeDigit
        /// Exactly three decimal digits, `\031`. Lua 5.1 has no `\x`.
        case decimalThreeDigit

        func render(_ scalar: Unicode.Scalar) -> String {
            switch self {
            case .hexTwoDigit: return String(format: "\\x%02x", scalar.value)
            case .unicodeFourDigitLowercase: return String(format: "\\u%04x", scalar.value)
            case .unicodeFourDigitUppercase: return String(format: "\\u%04X", scalar.value)
            case .octalThreeDigit: return String(format: "\\%03o", scalar.value)
            case .decimalThreeDigit: return String(format: "\\%03d", scalar.value)
            }
        }
    }

    public let controlForm: ControlCharacterForm
    /// Whether DEL (0x7F) is escaped like a control character.
    public let escapesDelete: Bool

    public init(controlForm: ControlCharacterForm, escapesDelete: Bool) {
        self.controlForm = controlForm
        self.escapesDelete = escapesDelete
    }

    // MARK: - Presets

    /// Python: `\xNN`. DEL passes through.
    public static let python = CStyleStringEscaping(controlForm: .hexTwoDigit, escapesDelete: false)
    /// R: backslash-u with four hex digits. DEL passes through.
    public static let r = CStyleStringEscaping(controlForm: .unicodeFourDigitLowercase, escapesDelete: false)
    /// Lua: three-digit decimal, which works in 5.1+ where `\xNN` is 5.2+;
    /// a literal newline inside a quoted string is a syntax error, so every
    /// control character is escaped.
    public static let lua = CStyleStringEscaping(controlForm: .decimalThreeDigit, escapesDelete: true)
    /// Octave: three-digit octal, because Octave's `\x` consumes every hex
    /// digit that follows (`"\x0abc"` swallows four characters of payload).
    public static let octave = CStyleStringEscaping(controlForm: .octalThreeDigit, escapesDelete: true)
    /// C++: three-digit octal, for the same reason as Octave — a hex escape
    /// has no length limit, so `\x1` followed by a literal `f` reads as one
    /// character.
    public static let cpp = CStyleStringEscaping(controlForm: .octalThreeDigit, escapesDelete: true)
    /// Java: three-digit octal, and NEVER a backslash-u escape. `javac`
    /// processes unicode escapes in the lexer, before it knows what a string
    /// literal is, so the escape for a newline becomes a real line break in
    /// the middle of the literal and the file fails to compile.
    public static let java = CStyleStringEscaping(controlForm: .octalThreeDigit, escapesDelete: true)
    /// Racket: backslash-u with four uppercase hex digits. Racket has no `\/`.
    public static let racket = CStyleStringEscaping(controlForm: .unicodeFourDigitUppercase, escapesDelete: true)

    // MARK: - Rendering

    /// The escaped contents of `s`, without surrounding quotes. Non-ASCII
    /// passes through as UTF-8; every target reads UTF-8 source.
    public func escapedContents(of s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += #"\\"#
            case "\"": out += #"\""#
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || (escapesDelete && scalar.value == 0x7F) {
                    out += controlForm.render(scalar)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// `s` as a double-quoted literal.
    public func quotedLiteral(_ s: String) -> String {
        "\"" + escapedContents(of: s) + "\""
    }
}
