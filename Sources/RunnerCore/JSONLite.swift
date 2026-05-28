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
        let text = String(chars[start..<pos])
        guard let d = Double(text) else { return nil }
        return .number(d)
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
