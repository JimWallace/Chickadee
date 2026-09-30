// A minimal JSON-Schema validator for checking a tool's actual
// `structuredContent` against its advertised `outputSchema`, the way an MCP
// client does (Claude's connector rejects a result that does not validate,
// even when the write it reports was applied).
//
// It covers exactly the keywords the catalog uses — `type` (single or array),
// `enum`, `properties`, `required`, `items`, `additionalProperties`,
// `minimum`, `maximum` — and reports any other keyword as a violation, so a
// schema that grows a new keyword cannot slip past this check unvalidated.

import Core

enum MCPOutputSchemaValidator {
    /// Keywords that annotate but never constrain.
    private static let annotationKeywords: Set<String> = ["description"]
    private static let checkedKeywords: Set<String> = [
        "type", "enum", "properties", "required", "items", "additionalProperties", "minimum", "maximum",
    ]

    /// Every violation of `schema` by `value`, as `path message` strings; empty
    /// when the value validates. Paths read like the clients' (`data/opensAt`).
    static func violations(of value: JSONValue, against schema: JSONValue, at path: String = "data") -> [String] {
        guard case .object(let keywords) = schema else {
            return ["\(path): schema is not an object"]
        }
        var found: [String] = []
        for key in keywords.keys.sorted() where !checkedKeywords.contains(key) && !annotationKeywords.contains(key) {
            found.append("\(path): unsupported schema keyword \"\(key)\"")
        }
        if let typeViolation = typeViolation(of: value, against: keywords["type"], at: path) {
            // A value of the wrong type makes the remaining checks noise.
            return found + [typeViolation]
        }
        if case .array(let options)? = keywords["enum"], !options.contains(value) {
            found.append("\(path) must be equal to one of the allowed values, got \(value)")
        }
        found += boundViolations(of: value, keywords: keywords, at: path)
        switch value {
        case .object(let fields):
            found += objectViolations(of: fields, keywords: keywords, at: path)
        case .array(let elements):
            if let itemSchema = keywords["items"] {
                for (index, element) in elements.enumerated() {
                    found += violations(of: element, against: itemSchema, at: "\(path)/\(index)")
                }
            }
        default:
            break
        }
        return found
    }

    private static func typeViolation(of value: JSONValue, against type: JSONValue?, at path: String) -> String? {
        var allowed: [String] = []
        switch type {
        case .string(let one)?:
            allowed = [one]
        case .array(let many)?:
            for case .string(let name) in many {
                allowed.append(name)
            }
        default:
            return nil
        }
        if allowed.contains(where: { matches(value, type: $0) }) {
            return nil
        }
        return "\(path) must be \(allowed.joined(separator: ",")), got \(typeName(value))"
    }

    private static func boundViolations(
        of value: JSONValue, keywords: [String: JSONValue], at path: String
    ) -> [String] {
        guard let actual = number(value) else { return [] }
        var found: [String] = []
        if let bound = number(keywords["minimum"]), actual < bound {
            found.append("\(path) must be >= \(bound)")
        }
        if let bound = number(keywords["maximum"]), actual > bound {
            found.append("\(path) must be <= \(bound)")
        }
        return found
    }

    private static func objectViolations(
        of fields: [String: JSONValue], keywords: [String: JSONValue], at path: String
    ) -> [String] {
        var found: [String] = []
        var properties: [String: JSONValue] = [:]
        if case .object(let declared)? = keywords["properties"] {
            properties = declared
        }
        if case .array(let required)? = keywords["required"] {
            for case .string(let key) in required where fields[key] == nil {
                found.append("\(path) must have required property '\(key)'")
            }
        }
        for key in fields.keys.sorted() {
            guard let child = fields[key] else { continue }
            if let childSchema = properties[key] {
                found += violations(of: child, against: childSchema, at: "\(path)/\(key)")
            } else if keywords["additionalProperties"] == .bool(false) {
                found.append("\(path) must NOT have additional property '\(key)'")
            }
        }
        return found
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("integer", .int), ("number", .int), ("number", .double),
            ("string", .string), ("array", .array), ("object", .object):
            return true
        case ("integer", .double(let d)):
            return d.rounded() == d
        default:
            return false
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return nil
        }
    }

    private static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
