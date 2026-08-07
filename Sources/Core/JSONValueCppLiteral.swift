// Core/JSONValueCppLiteral.swift
//
// Rendering a JSONValue as a C++ expression, for generated pattern-family
// tests. Split from JSONValue.swift for length; same shape as the other
// four literal renderers.

import Foundation

extension JSONValue {

    /// Render this value as a C++ expression.
    ///
    /// C++ is the first statically-typed target, and the rule that matters is
    /// the opposite of Octave's: nothing here may GUESS a type. Every rendered
    /// expression has one obvious type, and everything whose type would be a
    /// guess is refused at save time (`cppRenderabilityIssue`) rather than
    /// rendered plausibly-wrong:
    ///
    ///   - scalars render as themselves — `42`, `1.5`, `true`,
    ///     `std::string("...")` (a `std::string`, never a bare `const char*`,
    ///     so comparisons are by value and `auto` bindings behave);
    ///   - an int too wide for `int` takes the `LL` suffix, so the literal
    ///     itself never overflows;
    ///   - an array of one scalar kind renders as an explicitly-typed vector —
    ///     `std::vector<long long>{...}` (all ints), `std::vector<double>`
    ///     (any double among numerics), `std::vector<bool>`,
    ///     `std::vector<std::string>` — and the runtime's `ck::equal` compares
    ///     cross-type elementwise, so the student's `vector<int>` still
    ///     matches;
    ///   - an object with one scalar value kind renders as
    ///     `std::map<std::string, T>{{"k", v}, ...}`, keys sorted;
    ///   - **everything else is unrenderable**: JSON null (no C++ value;
    ///     `std::optional` would impose a signature convention on students),
    ///     mixed-kind arrays (`[1, "two"]` has no honest container), nested
    ///     arrays/objects-in-arrays (their element type would be a guess), and
    ///     heterogeneous object values.
    ///
    /// The renderer is deliberately TOTAL anyway: an unrenderable value that
    /// slips past validation emits an undefined identifier
    /// (`CK_UNRENDERABLE_...`), so the generated test fails to compile — a
    /// loud error attributed to authoring, never a plausible wrong value
    /// graded against students.
    public var cppLiteral: String {
        switch self {
        case .null:
            return "CK_UNRENDERABLE_NULL_HAS_NO_CPP_VALUE"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i):
            // Beyond `int`, an unsuffixed literal still compiles (the type
            // widens by rule), but the suffix states the intent and keeps the
            // rendered expression's type independent of the target's `int`.
            return (i > Int(Int32.max) || i < Int(Int32.min)) ? "\(i)LL" : String(i)
        case .double(let d):
            // The std spellings, not `0.0/0.0`: the generated expression may
            // land in a context the compiler constant-folds, where IEC 60559
            // division by zero is ill-formed. The runtime header guarantees
            // <cmath> and <limits>.
            if d.isNaN { return "std::nan(\"\")" }
            if d.isInfinite {
                return d < 0
                    ? "(-std::numeric_limits<double>::infinity())"
                    : "std::numeric_limits<double>::infinity()"
            }
            let s = String(d)
            return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
        case .string(let s):
            return "std::string(\(encodeCppString(s)))"
        case .array(let a):
            guard let element = cppVectorElementType(a) else {
                return "CK_UNRENDERABLE_ARRAY_HAS_NO_SINGLE_CPP_ELEMENT_TYPE"
            }
            let inner = a.map { $0.cppScalarLiteral(as: element) }.joined(separator: ", ")
            return "std::vector<\(element.spelled)>{\(inner)}"
        case .object(let o):
            let pairs = o.sorted { $0.key < $1.key }
            guard let element = cppVectorElementType(pairs.map(\.value)), !pairs.isEmpty else {
                return pairs.isEmpty
                    ? "std::map<std::string, double>{}"
                    : "CK_UNRENDERABLE_OBJECT_HAS_NO_SINGLE_CPP_VALUE_TYPE"
            }
            let rendered = pairs.map {
                "{\(encodeCppString($0.key)), \($0.value.cppScalarLiteral(as: element))}"
            }
            return "std::map<std::string, \(element.spelled)>{\(rendered.joined(separator: ", "))}"
        }
    }

    /// Why this value cannot be rendered as C++, or nil when it can — the
    /// save-time question. Validators call this so an instructor is refused
    /// with a named reason at authoring; `cppLiteral` stays total as the
    /// loud-compile-error backstop.
    public var cppRenderabilityIssue: String? {
        switch self {
        case .null:
            return "null has no C++ value; write the concrete value instead"
        case .bool, .int, .double, .string:
            return nil
        case .array(let a):
            if a.contains(where: { if case .null = $0 { return true } else { return false } }) {
                return "an array containing null has no C++ rendering"
            }
            guard cppVectorElementType(a) != nil else {
                return "a mixed or nested array has no single C++ element type; "
                    + "use one kind of scalar per array"
            }
            return nil
        case .object(let o):
            if o.values.contains(where: { if case .null = $0 { return true } else { return false } }) {
                return "an object containing null has no C++ rendering"
            }
            guard o.isEmpty || cppVectorElementType(Array(o.values)) != nil else {
                return "an object whose values mix kinds has no single C++ value type"
            }
            return nil
        }
    }

    /// This scalar, rendered for a container of `element` — the one place an
    /// int renders as a double (`std::vector<double>{1, 2.5}` would otherwise
    /// trip list-init narrowing for non-representable values).
    private func cppScalarLiteral(as element: CppElementType) -> String {
        if case .int(let i) = self, element == .double {
            return JSONValue.double(Double(i)).cppLiteral
        }
        return cppLiteral
    }
}

/// The single element type a C++ container rendering needs, or nil when the
/// elements do not share one.
private enum CppElementType: Equatable {
    case longLong
    case double
    case bool
    case string

    var spelled: String {
        switch self {
        case .longLong: return "long long"
        case .double: return "double"
        case .bool: return "bool"
        case .string: return "std::string"
        }
    }
}

/// Classify an array's single C++ element type. Empty arrays render as
/// `std::vector<double>{}` — the shape still compares (elementwise over
/// nothing), and double is the JSON number type. Bool is its own kind here,
/// NOT folded into the numerics: `std::vector<bool>{true, 1.5}` would be a
/// silent re-reading of the author's value.
private func cppVectorElementType(_ items: [JSONValue]) -> CppElementType? {
    guard !items.isEmpty else { return .double }
    var sawDouble = false
    var sawInt = false
    var sawBool = false
    var sawString = false
    for item in items {
        switch item {
        case .int: sawInt = true
        case .double: sawDouble = true
        case .bool: sawBool = true
        case .string: sawString = true
        case .null, .array, .object: return nil
        }
    }
    switch (sawString, sawBool, sawDouble, sawInt) {
    case (true, false, false, false): return .string
    case (false, true, false, false): return .bool
    case (false, false, true, _): return .double
    case (false, false, false, true): return .longLong
    default: return nil
    }
}

/// C++ string literals take C escapes. Control characters use
/// exactly-three-digit octal (`\011`) rather than `\x`, for the same reason
/// Octave's encoder does: `\x` consumes every hex digit that follows, so
/// `"\x0abc"` would swallow payload, while octal stops at three digits by
/// rule. Non-ASCII passes through as UTF-8 source bytes, which C++ string
/// literals carry verbatim.
private func encodeCppString(_ s: String) -> String {
    var out = "\""
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
    return out + "\""
}
