// APIServer/Models/JSONColumn.swift
//
// Encoding for a model column that stores a small Codable value as JSON
// text. `RunnerProfile` and `AssignmentRequirement` both keep two such
// columns behind a computed struct projection, and both carried a private
// copy of this pair. Keys are sorted so the stored text is stable for equal
// values.

import Foundation

enum JSONColumn {
    /// `value` as sorted-key JSON text; `"[]"` when encoding fails.
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    /// The value stored in `raw`, or `defaultValue` when the text does not
    /// decode.
    static func decode<T: Decodable>(_ raw: String, defaultValue: T) -> T {
        guard let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(T.self, from: data)
        else {
            return defaultValue
        }
        return decoded
    }
}
