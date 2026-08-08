// Core/JSONValueRacketLiteral.swift
//
// Rendering a JSONValue as a Racket expression, for generated pattern-family
// tests. Split from JSONValue.swift for length; same shape as the other five
// literal renderers.

import Foundation

extension JSONValue {

    /// Render this value as a Racket expression.
    ///
    /// This is the OPPOSITE of the C++ renderer's problem, and the reason
    /// Racket was the cheapest language to add. C++ is statically typed, so
    /// `[1, "two"]` has no honest rendering and a refusal table
    /// (`cppRenderabilityIssue`) had to exist. Racket is dynamically typed:
    /// heterogeneous lists, nesting and mixed-value hashes are all ordinary
    /// values, so **nothing is unrenderable** and there is no companion
    /// `racketRenderabilityIssue`. Its absence is the point, not an omission.
    ///
    /// The literals land in the GENERATED TEST, which is always `#lang racket`
    /// — never in the student's file, which may be an HtDP teaching language.
    /// So full-Racket syntax is available here even when grading `#lang
    /// htdp/bsl` submissions, and that asymmetry is what keeps one generated
    /// test working across both dialects.
    public var racketLiteral: String {
        switch self {
        case .null:
            // Racket's own `json` library reads JSON null as the symbol
            // `'null` (the default of the `json-null` parameter), so an
            // instructor who writes null gets the value Racket itself would
            // have produced. `'()` would be wrong — that is the empty list, a
            // different value that an expectation could legitimately want —
            // and `#f` would collide with boolean false for the same reason.
            return "'null"
        case .bool(let b):
            return b ? "#t" : "#f"
        case .int(let i):
            // Racket integers are arbitrary precision, so no suffix or width
            // question arises — the C++ renderer's `LL` problem has no analogue.
            return String(i)
        case .double(let d):
            // Racket's own reader syntax for the non-finite flonums. `(/ 0. 0.)`
            // would also produce them but reads as a computation rather than a
            // value.
            if d.isNaN { return "+nan.0" }
            if d.isInfinite { return d < 0 ? "-inf.0" : "+inf.0" }
            let s = String(d)
            // Keep it a flonum: `2.0` must not render as `2`, which Racket
            // reads as an exact integer and which `equal?` then distinguishes.
            return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
        case .string(let s):
            return encodeRacketString(s)
        case .array(let a):
            // `(list ...)` rather than a quoted `'(...)`: quote would suppress
            // evaluation of the elements, so a nested `(hash ...)` or a
            // `$name` reference inside would render as literal source text
            // instead of the value it names.
            return a.isEmpty ? "(list)" : "(list " + a.map(\.racketLiteral).joined(separator: " ") + ")"
        case .object(let o):
            // An immutable hash with string keys, which is what Racket's json
            // reader produces for a JSON object modulo key type, and which
            // `equal?` compares structurally.
            guard !o.isEmpty else { return "(hash)" }
            let pairs = o.sorted { $0.key < $1.key }
                .map { "\(encodeRacketString($0.key)) \($0.value.racketLiteral)" }
            return "(hash " + pairs.joined(separator: " ") + ")"
        }
    }
}

/// Racket string syntax. The escape set is Racket's, not JSON's — they agree on
/// the common cases but Racket has no `\/`, and a literal backslash must be
/// doubled before anything else is considered.
private func encodeRacketString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            // Racket source is UTF-8, so printable non-ASCII needs no escape.
            // Control characters do: they would otherwise be embedded raw and
            // make the generated file unreadable (and, for a stray NUL,
            // unparseable).
            if scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\u%04X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
