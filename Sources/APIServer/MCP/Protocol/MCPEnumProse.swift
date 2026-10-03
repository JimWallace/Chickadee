// APIServer/MCP/Protocol/MCPEnumProse.swift
//
// The renderings every agent-facing enum needs, derived from `allCases` in one
// place (#1938): the inline lists a tool description uses, the JSON Schema
// `enum` array, and the parser that refuses an unknown wire token with the
// legal values.
//
// Each prose module (MCPTierProse, MCPFailureDetailProse, MCPPatternKindProse
// and the others) wrote these renderings again for its own enum, and four tool
// schemas still typed their `enum` arrays and error messages by hand. The
// per-case glosses stay in their modules, because a gloss is per case by
// nature; the renderings live here.

import Core

/// The renderings of `Value`'s cases, in declaration order.
enum MCPEnumProse<Value: CaseIterable & RawRepresentable> where Value.RawValue == String {

    /// Every case's wire token.
    static var tokens: [String] { Value.allCases.map(\.rawValue) }

    /// `"a/b/c"`, for an inline parenthetical.
    static var slashAlternatives: String { tokens.joined(separator: "/") }

    /// `"a / b / c"`, for a longer inline list.
    static var slashSeparated: String { tokens.joined(separator: " / ") }

    /// `"a, b, c"`, for a "must be one of" error. No conjunction: these are
    /// literal values a caller matches exactly, not a sentence.
    static var oneOfList: String { tokens.joined(separator: ", ") }

    /// `"a, b or c"`, for a sentence.
    static var orList: String { LanguageProse.list(tokens) }

    /// `"\"a\", \"b\" or \"c\""`, for a sentence that quotes the tokens.
    static var quotedOrList: String { LanguageProse.list(tokens.map { "\"\($0)\"" }) }

    /// `"\"a\" | \"b\" | \"c\""`, for a field description that reads as a union.
    static var quotedUnion: String { tokens.map { "\"\($0)\"" }.joined(separator: " | ") }

    /// The JSON Schema `enum` array.
    static var jsonEnum: JSONValue { .array(tokens.map { .string($0) }) }

    /// A string property restricted to the cases. Not called `schema(_:)`:
    /// that is Fluent's word for changing a database, and the guard that finds
    /// schema-changing test suites reads `.schema(` as one.
    static func stringSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": jsonEnum,
            "description": .string(description),
        ])
    }

    /// The case for `raw`, or a tool error that names `field` and the legal
    /// values.
    static func parse(_ raw: String, tool: String, field: String) throws -> Value {
        guard let value = Value(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "\(field) must be one of: \(oneOfList).")
        }
        return value
    }

    /// `parse` for an optional argument: nil in, nil out.
    static func parseOptional(_ raw: String?, tool: String, field: String) throws -> Value? {
        guard let raw else { return nil }
        return try parse(raw, tool: tool, field: field)
    }
}
