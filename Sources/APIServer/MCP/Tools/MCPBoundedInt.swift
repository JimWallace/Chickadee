// APIServer/MCP/Tools/MCPBoundedInt.swift
//
// An optional integer argument with a default and an upper bound, such as a
// list limit or a look-back window. Thirteen tools clamped one by hand and
// typed the default and the maximum again in their served prose, and no schema
// declared the range (#2336). The bound now renders its own schema and prose.

import Core

struct MCPBoundedInt: Sendable {
    let defaultValue: Int
    let maximum: Int

    init(default defaultValue: Int, max maximum: Int) {
        self.defaultValue = defaultValue
        self.maximum = maximum
    }

    /// `"(default 20, max 100)"`, for a description.
    var rangeText: String { "(default \(defaultValue), max \(maximum))" }

    /// The input property: an integer from 1 to `maximum`, described as
    /// `"<what> (default …, max …)."`. Not called `schema(_:)`: the guard that
    /// finds schema-changing test suites reads `.schema(` as Fluent's.
    func property(_ what: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string("\(what) \(rangeText)."),
            "minimum": .int(1),
            "maximum": .int(maximum),
        ])
    }

    /// The value to use: the default when absent, else the request clamped to
    /// 1...maximum.
    func resolve(_ requested: Int?) -> Int {
        min(max(requested ?? defaultValue, 1), maximum)
    }
}
