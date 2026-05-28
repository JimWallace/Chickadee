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
            guard let digit = chars[pos].hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
            pos += 1
        }
        return Unicode.Scalar(value)
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

    /// Parse a JSON number literal to `Double` WITHOUT `Double(String)`: the
    /// latter lowers to `_swift_stdlib_strtod_clocale`, which the Embedded Swift
    /// wasm runtime does not provide (it becomes a link error the moment the
    /// browser bridge reaches this path via `executeSuites`). The value here is
    /// a footer's reserved `score`, which `interpretScriptOutput` never reads —
    /// we only need a finite `Double` so the enclosing object parses. Shared by
    /// the native and embedded builds (one implementation, no drift); precise to
    /// full `Double` for typical inputs via an integer mantissa + decimal scale.
    static func parseDoubleLiteral(_ slice: ArraySlice<Character>) -> Double? {
        let chars = Array(slice)
        let count = chars.count
        var index = 0
        guard count > 0 else { return nil }

        var sign = 1.0
        if chars[index] == "-" {
            sign = -1.0
            index += 1
        } else if chars[index] == "+" {
            index += 1
        }

        var mantissa = 0.0
        var fractionDigits = 0
        var sawDigit = false
        while index < count, let digit = asciiDigit(chars[index]) {
            mantissa = mantissa * 10 + Double(digit)
            index += 1
            sawDigit = true
        }
        if index < count, chars[index] == "." {
            index += 1
            while index < count, let digit = asciiDigit(chars[index]) {
                mantissa = mantissa * 10 + Double(digit)
                fractionDigits += 1
                index += 1
                sawDigit = true
            }
        }
        guard sawDigit else { return nil }

        var exponent = 0
        if index < count, chars[index] == "e" || chars[index] == "E" {
            index += 1
            var exponentSign = 1
            if index < count, chars[index] == "-" {
                exponentSign = -1
                index += 1
            } else if index < count, chars[index] == "+" {
                index += 1
            }
            var sawExponentDigit = false
            while index < count, let digit = asciiDigit(chars[index]) {
                exponent = exponent * 10 + digit
                index += 1
                sawExponentDigit = true
            }
            guard sawExponentDigit else { return nil }
            exponent *= exponentSign
        }
        guard index == count else { return nil }

        return sign * mantissa * powerOfTen(exponent - fractionDigits)
    }

    /// ASCII digit value (0–9) or nil — avoids `wholeNumberValue` (Unicode
    /// tables) and force-unwrapping, keeping number parsing embedded-clean.
    private static func asciiDigit(_ c: Character) -> Int? {
        guard let ascii = c.asciiValue, ascii >= 48, ascii <= 57 else { return nil }
        return Int(ascii - 48)
    }

    /// `10` raised to an integer power via repeated f64 multiply/divide — no
    /// `pow` (libm) dependency.
    private static func powerOfTen(_ exponent: Int) -> Double {
        var result = 1.0
        var remaining = exponent >= 0 ? exponent : -exponent
        while remaining > 0 {
            result *= 10
            remaining -= 1
        }
        return exponent >= 0 ? result : 1.0 / result
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
