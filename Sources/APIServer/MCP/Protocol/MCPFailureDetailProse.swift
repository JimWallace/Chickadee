// APIServer/MCP/Protocol/MCPFailureDetailProse.swift
//
// How `FailureDetail` is spelled in the agent-facing copy and parsed off the
// wire — derived from `FailureDetail.allCases` in one place, for the same
// reason `MCPTierProse` exists: prose is the one surface no compiler and no
// `allCases` test reaches, so a list typed by hand stays typed. No tool
// description names a level; every rendering comes from here.

import Core

/// The student-facing failure-detail levels, rendered for agent-facing copy.
enum MCPFailureDetailProse {

    /// `"full/actualOnly/verdictOnly"` for an inline parenthetical.
    static var slashAlternatives: String {
        FailureDetail.allCases.map(\.rawValue).joined(separator: "/")
    }

    /// `"full, actualOnly, verdictOnly"` for a "must be one of" error.
    static var oneOfList: String {
        FailureDetail.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// Each level with its one-line meaning, for a tool description:
    /// `"full" (…); "actualOnly" (…); "verdictOnly" (…)`.
    static var glossedList: String {
        FailureDetail.allCases.map { "\"\($0.rawValue)\" (\($0.summary))" }.joined(separator: "; ")
    }

    /// The JSON-schema property every tool that takes a level shares.
    static func schema(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(FailureDetail.allCases.map { .string($0.rawValue) }),
            "description": .string(description),
        ])
    }

    /// Parses an optional wire value: absent or empty → nil (no value, or
    /// "clear" on an edit path), `"full"` → nil (the default is stored as
    /// absence), any other level → itself, anything else refused with the
    /// accepted list. Returns a double optional so an edit path can tell
    /// "not mentioned" (`.none`) from "clear it" (`.some(nil)`).
    static func parse(_ raw: String?, tool: String, field: String) throws -> FailureDetail?? {
        guard let raw else { return .none }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let detail = FailureDetail(rawValue: trimmed) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "\(field) must be one of: \(oneOfList).")
        }
        return .some(detail == .full ? nil : detail)
    }

    /// `parse` flattened for a CREATE path, where "not mentioned" and "clear"
    /// both mean the default: nil unless a non-default level was given.
    static func parseValue(_ raw: String?, tool: String, field: String) throws -> FailureDetail? {
        switch try parse(raw, tool: tool, field: field) {
        case .none: return nil
        case .some(let value): return value
        }
    }

    /// The description sentence shared by every authoring tool that takes a
    /// level.
    static let fieldDescription: String =
        "How much of a FAILING run the student is shown, applied at results-display time: "
        + "\(glossedList). Staff always see everything. Omit or \"full\" for the default."
}
