// APIServer/MCP/Protocol/MCPProgramIOProse.swift
//
// How a `program_io` family's `ioComparison` is SPELLED in the agent-facing
// schema, derived from `ProgramIOComparison.allCases` so the enum and the
// prose cannot disagree — the same posture as MCPPatternKindProse and
// MCPFailureDetailProse.

import Core
import Vapor

enum MCPProgramIOProse {

    /// One clause per comparison, joined into the field description.
    static func gloss(for comparison: ProgramIOComparison) -> String {
        switch comparison {
        case .exact: return "the whole output must equal the expected text"
        case .included: return "the output must contain the expected text"
        case .regex: return "the output must match the expected regular expression"
        }
    }

    static var tokens: [String] { ProgramIOComparison.allCases.map(\.rawValue) }

    static var fieldDescription: String {
        let glossed = ProgramIOComparison.allCases.map { "\($0.rawValue) (\(gloss(for: $0)))" }
        return "Read by kind=program_io only: how each case's expected text is matched against "
            + "what the program printed. One of " + glossed.joined(separator: ", ")
            + ". Trailing whitespace on each line and trailing blank lines are ignored for "
            + "exact. Omit for exact. regex is refused on a Lua assignment."
    }

    static var schema: JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(tokens.map { .string($0) }),
            "description": .string(fieldDescription),
        ])
    }

    /// nil in → nil out (leave unchanged / default); an unknown token is a
    /// tool error naming the legal values.
    static func parse(_ raw: String?, tool: String) throws -> ProgramIOComparison? {
        guard let raw else { return nil }
        guard let parsed = ProgramIOComparison(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "ioComparison must be one of: \(tokens.joined(separator: ", ")).")
        }
        return parsed
    }
}
