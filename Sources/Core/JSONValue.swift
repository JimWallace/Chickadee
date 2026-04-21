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
        if let b = try? c.decode(Bool.self)              { self = .bool(b);   return }
        if let i = try? c.decode(Int.self)               { self = .int(i);    return }
        if let d = try? c.decode(Double.self)            { self = .double(d); return }
        if let s = try? c.decode(String.self)            { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)       { self = .array(a);  return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Value is not a recognised JSON type (null, bool, number, string, array, object)."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
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
        case .null:          return "None"
        case .bool(let b):   return b ? "True" : "False"
        case .int(let i):    return String(i)
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
}

private func encodePythonString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\":  out += #"\\"#
        case "\"":  out += #"\""#
        case "\n":  out += "\\n"
        case "\r":  out += "\\r"
        case "\t":  out += "\\t"
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
