// A tiny, dependency-free JSON value parser — enough to recognise a script's
// optional last-line result footer and read its fields, without Foundation's
// JSONDecoder (unavailable in Embedded Swift). Stdlib only.

enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

/// Parse a complete JSON document. Returns nil if `text` is not well-formed
/// JSON or has trailing non-whitespace.
func parseJSON(_ text: String) -> JSONValue? {
    var parser = JSONParser(Array(text))
    parser.skipWhitespace()
    guard let value = parser.parseValue() else { return nil }
    parser.skipWhitespace()
    guard parser.isAtEnd else { return nil }
    return value
}

private struct JSONParser {
    private let chars: [Character]
    private var pos: Int = 0

    init(_ chars: [Character]) { self.chars = chars }

    var isAtEnd: Bool { pos >= chars.count }
    private var current: Character? { pos < chars.count ? chars[pos] : nil }

    mutating func skipWhitespace() {
        while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" { pos += 1 }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        switch current {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map(JSONValue.string)
        case "t", "f": return parseBool()
        case "n": return parseNull()
        case .some(let c) where c == "-" || (c >= "0" && c <= "9"): return parseNumber()
        default: return nil
        }
    }

    private mutating func parseObject() -> JSONValue? {
        pos += 1  // consume '{'
        var dict: [String: JSONValue] = [:]
        skipWhitespace()
        if current == "}" { pos += 1; return .object(dict) }
        while true {
            skipWhitespace()
            guard current == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard current == ":" else { return nil }
            pos += 1
            guard let value = parseValue() else { return nil }
            dict[key] = value
            skipWhitespace()
            switch current {
            case ",": pos += 1
            case "}": pos += 1; return .object(dict)
            default: return nil
            }
        }
    }

    private mutating func parseArray() -> JSONValue? {
        pos += 1  // consume '['
        var items: [JSONValue] = []
        skipWhitespace()
        if current == "]" { pos += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            switch current {
            case ",": pos += 1
            case "]": pos += 1; return .array(items)
            default: return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        guard current == "\"" else { return nil }
        pos += 1
        var out = ""
        while let c = current {
            pos += 1
            if c == "\"" { return out }
            if c == "\\" {
                guard let esc = current else { return nil }
                pos += 1
                if esc == "u" {
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    out.append(Character(scalar))
                } else if let mapped = JSONParser.simpleEscape(esc) {
                    out.append(mapped)
                } else {
                    return nil
                }
            } else {
                out.append(c)
            }
        }
        return nil  // unterminated
    }

    /// Maps a single-character escape (other than `\u`) to its character.
    static func simpleEscape(_ c: Character) -> Character? {
        switch c {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        default: return nil
        }
    }

    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        guard pos + 4 <= chars.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = asciiHexValue(chars[pos]) else { return nil }
            value = value * 16 + digit
            pos += 1
        }
        return Unicode.Scalar(value)
    }

    /// ASCII hex digit value (0–15), or nil.  JSON `\uXXXX` escapes are ASCII
    /// hex by definition, so this is behaviour-identical to
    /// `Character.hexDigitValue` — but it avoids pulling Unicode numeric-property
    /// tables into the Embedded wasm build.
    private func asciiHexValue(_ c: Character) -> UInt32? {
        guard let b = c.asciiValue else { return nil }
        switch b {
        case 0x30...0x39: return UInt32(b - 0x30)  // 0–9
        case 0x41...0x46: return UInt32(b - 0x41 + 10)  // A–F
        case 0x61...0x66: return UInt32(b - 0x61 + 10)  // a–f
        default: return nil
        }
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = pos
        if current == "-" { pos += 1 }
        while let c = current, (c >= "0" && c <= "9") || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
            pos += 1
        }
        guard let value = JSONParser.parseDoubleLiteral(chars[start..<pos]) else { return nil }
        return .number(value)
    }

    /// Parse a JSON number literal to `Double`.
    ///
    /// `Double(String)` is the whole implementation. It used to be a hand-rolled
    /// mantissa-times-power-of-ten fold, because `Double(String)` lowered to
    /// `_swift_stdlib_strtod_clocale`, which the Embedded Swift runtime did not
    /// provide, and the browser bridge hit that as a link error the moment
    /// `executeSuites` reached this path. Swift 6.4 reimplemented string-to-
    /// double parsing for Embedded Swift, so the initializer links in the wasm
    /// build again (measured: it links, and returns correct values when the
    /// Embedded wasm build is driven from Node).
    ///
    /// The fold was not merely longer; it was WRONG by one unit in the last
    /// place for ordinary inputs, because each `mantissa * 10` and the final
    /// multiply by a repeated-product power of ten each round separately.
    /// `"0.7"` parsed to `0.7000000000000001`, `"0.3"` to `0.30000000000000004`,
    /// `"1e308"` to `9.999999999999998e+307`, `"1.7976931348623157e308"` to
    /// `inf`, and the smallest normal double to `0`. A footer's `score` is
    /// multiplied by `points` and a `metric` is compared for ranking, so the
    /// error was observable in a grade. `Double(String)` is correctly rounded.
    /// `JSONFooterNumberExactnessTests` pins the cases above.
    ///
    /// `parseNumber` has already restricted the slice to `[0-9.eE+-]`, so none
    /// of the spellings `Double(String)` accepts beyond JSON's grammar (`inf`,
    /// `nan`, hexadecimal floats) can reach here. A leading `+` still parses,
    /// as it always did; `JSONFooterGrammarTests` pins that tolerance.
    static func parseDoubleLiteral(_ slice: ArraySlice<Character>) -> Double? {
        guard !slice.isEmpty else { return nil }
        return Double(String(slice))
    }

    private mutating func parseBool() -> JSONValue? {
        if matchLiteral("true") { return .bool(true) }
        if matchLiteral("false") { return .bool(false) }
        return nil
    }

    private mutating func parseNull() -> JSONValue? {
        matchLiteral("null") ? .null : nil
    }

    private mutating func matchLiteral(_ literal: String) -> Bool {
        let lit = Array(literal)
        guard pos + lit.count <= chars.count else { return false }
        for (offset, ch) in lit.enumerated() where chars[pos + offset] != ch { return false }
        pos += lit.count
        return true
    }
}
