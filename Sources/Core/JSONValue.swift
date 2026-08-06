// Core/JSONValue.swift
//
// A typed representation of a JSON value used by pattern families to describe
// test case inputs and expected outputs in a way that round-trips through
// JSON and can be rendered deterministically as Python literals.
//
// Kept in Core because PatternFamily is part of the manifest schema and Core
// is the only target the manifest types live in.

import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Order matters: Int before Double so whole numbers round-trip as int.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Value is not a recognised JSON type (null, bool, number, string, array, object)."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Deterministic Python literal representation, suitable for embedding
    /// inside generated test scripts.  Matches JSON syntax except:
    ///   - null → None
    ///   - true/false → True/False
    ///   - object keys kept in sorted order so the rendered source is stable
    public var pythonLiteral: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d):
            // Ensure the literal parses as a Python float even for whole-number
            // values (e.g. 2.0 -> "2.0", not "2.0000000…").  Swift's default
            // Double description already produces a minimal round-trippable form.
            let s = String(d)
            return (s.contains(".") || s.contains("e") || s.contains("n")) ? s : s + ".0"
        case .string(let s):
            return encodePythonString(s)
        case .array(let a):
            return "[" + a.map(\.pythonLiteral).joined(separator: ", ") + "]"
        case .object(let o):
            let pairs = o.sorted { $0.key < $1.key }
                .map { "\(encodePythonString($0.key)): \($0.value.pythonLiteral)" }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }

    /// Deterministic R literal representation, suitable for embedding inside
    /// generated R test scripts and the `_ck_inputs.R` inputs file. Mirrors
    /// `pythonLiteral` but emits R syntax:
    ///   - null → NA; true/false → TRUE/FALSE
    ///   - an array whose elements are all the same scalar kind (all logical,
    ///     all numeric, or all character), optionally interleaved with nulls
    ///     → `c(...)`; anything else (mixed kinds, nested, containing objects,
    ///     or empty) → `list(...)`
    ///   - object → named `list(...)` with keys in sorted order
    ///
    /// A JSON null is a *missing value*, which in R is `NA` — not `NULL`.
    /// `NULL` is a zero-length object that silently vanishes inside `c()`, so
    /// rendering it here would shorten the vector and break the alignment an
    /// authored case depends on (`[60, null, 20]` must stay length 3).
    public var rLiteral: String {
        switch self {
        case .null: return "NA"
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .int(let i): return String(i)
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d.isInfinite { return d < 0 ? "-Inf" : "Inf" }
            // Keep it a valid R numeric literal (e.g. 2 -> "2.0").
            let s = String(d)
            return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
        case .string(let s):
            return encodeRString(s)
        case .array(let a):
            let inner = a.map(\.rLiteral).joined(separator: ", ")
            return isHomogeneousScalarArray(a) ? "c(\(inner))" : "list(\(inner))"
        case .object(let o):
            let pairs = o.sorted { $0.key < $1.key }
                .map { "\(encodeRName($0.key)) = \($0.value.rLiteral)" }
            return "list(" + pairs.joined(separator: ", ") + ")"
        }
    }

    /// Deterministic Lua literal representation, suitable for embedding inside
    /// generated Lua test scripts and the `_ck_inputs.lua` inputs file.
    ///
    /// Lua has ONE composite type, so both a JSON array and a JSON object
    /// render as a table constructor — `{1, 2, 3}` and `{["a"] = 1}`. Keys are
    /// always bracketed-and-quoted rather than using the bare `a = 1` form,
    /// because a JSON key may be a Lua reserved word (`end`, `then`, `nil`) or
    /// contain characters no identifier can; quoting every key is uniformly
    /// correct and keeps the output stable under a key rename.
    ///
    /// The awkward case is `null`, which Lua spells `nil` — and a `nil` inside
    /// a table constructor is not stored at all, which silently breaks the
    /// positional alignment an authored case depends on. Measured on lua 5.4,
    /// `{60, nil, 20}`:
    ///   - `ipairs` stops at the hole and visits **one** element, not three;
    ///   - `table.concat` raises `invalid value (nil) at index 2`;
    ///   - `#t` is *unspecified* — it happens to answer 3 here, which makes it
    ///     the worst kind of bug: it looks fine until the allocation differs.
    ///
    /// This is the same trap `rLiteral` documents for R's `NULL`. R's answer is
    /// `NA`; Lua has no missing-value scalar, so the answer here is a
    /// **sentinel table**, `chickadee.NULL`, which is a real value and occupies
    /// its slot (`ipairs` then visits all three). It is defined by
    /// `test_runtime.lua`, so a generated script must bind the runtime under
    /// exactly that name — `local chickadee = require("test_runtime")` — and
    /// compares against it with `chickadee.equal`, which treats the sentinel as
    /// equal only to itself.
    ///
    /// A bare `nil` is used only where a value stands alone (an input, a scalar
    /// expected value), where nothing can be misaligned.
    public var luaLiteral: String {
        luaLiteral(inTable: false)
    }

    private func luaLiteral(inTable: Bool) -> String {
        switch self {
        case .null:
            // See the note above: inside a constructor a `nil` would not occupy
            // its slot, so the sentinel stands in for it there and only there.
            return inTable ? "chickadee.NULL" : "nil"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            // Lua 5.4 distinguishes integers from floats, and `1` would come
            // back as an integer where the author wrote a float. `0/0` and
            // `1/0` are how Lua spells the non-finite literals it cannot parse.
            if d.isNaN { return "(0/0)" }
            if d.isInfinite { return d < 0 ? "(-1/0)" : "(1/0)" }
            let s = String(d)
            return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
        case .string(let s):
            return encodeLuaString(s)
        case .array(let a):
            return "{" + a.map { $0.luaLiteral(inTable: true) }.joined(separator: ", ") + "}"
        case .object(let o):
            let pairs = o.sorted { $0.key < $1.key }
                .map { "[\(encodeLuaString($0.key))] = \($0.value.luaLiteral(inTable: true))" }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}

/// Lua's string escapes are C-like and overlap Python's, but `\xNN` is a Lua
/// 5.2+ feature and a literal newline inside a quoted string is a syntax error,
/// so every control character is escaped rather than passed through.
private func encodeLuaString(_ s: String) -> String {
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
                out += String(format: "\\%03d", ch.value)  // decimal: works in 5.1+
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "\""
}

private func encodePythonString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\x%02x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    out += "\""
    return out
}

/// True when every element is a scalar of the *same* R atomic kind (all
/// logical, all numeric — int/double mix is fine — or all character), so the
/// array renders as a homogeneous `c(...)` vector. Empty arrays and anything
/// containing arrays / objects fall through to `list(...)` (base R's `c()`
/// would flatten nested vectors).
///
/// Nulls are *wildcards*: they render as `NA`, which R admits into an atomic
/// vector of any type, so `[60, null, 20]` is still a numeric vector and
/// `["G2", null, "G4"]` is still a character one. An all-null array is
/// homogeneous too — `c(NA, NA)` is a logical NA vector, which is what R's own
/// JSON readers produce. Without this, a single authored null would demote the
/// whole case to `list(...)` and the student's function would be handed a list
/// where it expects an atomic vector.
private func isHomogeneousScalarArray(_ items: [JSONValue]) -> Bool {
    guard !items.isEmpty else { return false }
    // nil = null (compatible with every kind); .some(nil) = not a scalar at all.
    func kind(_ v: JSONValue) -> Int?? {
        switch v {
        case .null: return Int??.some(nil)
        case .bool: return 0
        case .int, .double: return 1  // numeric
        case .string: return 2
        case .array, .object: return Int??.none
        }
    }
    var seen: Int?
    for item in items {
        guard let scalar = kind(item) else { return false }  // array / object
        guard let k = scalar else { continue }  // null: compatible with anything
        if let s = seen, s != k { return false }
        seen = k
    }
    return true
}

private func encodeRString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    out += "\""
    return out
}

/// Renders an object key as an R `list(...)` name: bare when it is a simple
/// syntactic name (letters/digits/`.`/`_`, not starting with a digit), else a
/// quoted string (R accepts `list("a b" = 1)`).
private func encodeRName(_ s: String) -> String {
    let isSyntactic: Bool = {
        guard let first = s.first, first.isLetter || first == "." else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
    }()
    return isSyntactic ? s : encodeRString(s)
}
