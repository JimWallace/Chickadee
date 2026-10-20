// Core/JSONValueAccessors.swift
//
// Read access to a `JSONValue`, for code that walks parsed JSON: the
// replacement for `as? String`, `as? [Any]` and `as? [String: Any]` casts on
// the output of `JSONSerialization`. Each accessor returns nil when the value
// is of a different type, the same as the cast it replaces.

public import Foundation

extension JSONValue {

    /// The string, or nil when this is not a string.
    public var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    /// The elements, or nil when this is not an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let elements) = self { elements } else { nil }
    }

    /// The members, or nil when this is not an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { members } else { nil }
    }

    /// The elements as objects, or nil when this is not an array or when any
    /// element is not an object. The same as `as? [[String: Any]]`, which
    /// fails for the whole array when one element does not match.
    public var arrayOfObjects: [[String: JSONValue]]? {
        guard let elements = arrayValue else { return nil }
        let objects = elements.compactMap(\.objectValue)
        return objects.count == elements.count ? objects : nil
    }

    /// The member named `key`, or nil when this is not an object or has no
    /// such member.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The top-level object of `data`, or nil when `data` is not valid JSON or
    /// is not an object.
    ///
    /// Every value is decoded, so invalid JSON anywhere in `data` gives nil,
    /// as `JSONSerialization` does. Two differences remain: UTF-32 input with
    /// a byte-order mark is not read, and when a key appears twice the first
    /// value wins, not the last.
    public static func object(from data: Data) -> [String: JSONValue]? {
        try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    /// `object` as compact JSON with its keys sorted, or nil when it cannot be
    /// encoded (a double that is not finite).
    ///
    /// Sorted keys make the bytes deterministic: the same object always gives
    /// the same bytes, so a notebook that did not change hashes the same.
    /// `JSONSerialization` wrote keys in dictionary order, which changes from
    /// one process to the next.
    public static func data(fromObject object: [String: JSONValue]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(object)
    }
}
