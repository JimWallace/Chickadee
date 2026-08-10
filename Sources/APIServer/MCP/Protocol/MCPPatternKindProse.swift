// APIServer/MCP/Protocol/MCPPatternKindProse.swift
//
// How the pattern-family kinds are SPELLED in the agent-facing copy — the
// `initialize` instructions, the `create_pattern_family` description, and that
// tool's JSON `enum` — derived from `PatternKind.allCases` in one place.
//
// The sibling of MCPLanguageProse, for the same reason and after the same
// finding. That file exists because a hand-typed LANGUAGE list in agent-facing
// prose went stale twice (#1288, then #1308). The kind lists had the identical
// shape and had not been looked at: three of them, all hand-typed, and adding
// `differential` made all three wrong at once — an agent would have been told
// the kind does not exist while `get_server_info`, which derives its list from
// `allCases`, reported that it does.
//
// The guarantee here is stronger than a test. `gloss(for:)` is an exhaustive
// switch, so a new `PatternKind` does not compile until it says what it is, and
// every rendering below is built from `allCases` over that. A ninth kind needs
// no edit to any description or schema.

import Core

/// The pattern-family kinds, rendered for the places agent-facing copy needs
/// them.
enum MCPPatternKindProse {

    /// One short phrase per kind, for a reader deciding which to reach for.
    ///
    /// EXHAUSTIVE ON PURPOSE — this is the compile error a new kind gets, and
    /// it is the only place in the MCP surface that has to be told about one.
    /// Keep each to a clause: these are joined into a sentence.
    static func gloss(for kind: PatternKind) -> String {
        switch kind {
        case .boundaryEquality: return "a function's return equals an expected value"
        case .approximateEquality: return "a function's return is within a tolerance of one"
        case .variableEquality: return "a module-level variable equals a value"
        case .returnTypeCheck: return "a function returns a value of an expected type"
        case .exceptionExpected: return "a function raises an expected error"
        case .performanceThreshold: return "a function completes within a time budget"
        case .stdoutEquality: return "a function prints expected output"
        case .unorderedEquality:
            return "a function's return equals an expected collection ignoring order"
        case .differential:
            return "a function agrees with a reference implementation you supply, "
                + "which computes each case's expected value"
        }
    }

    /// Every kind's wire token, in declaration order.
    static var tokens: [String] { PatternKind.allCases.map(\.rawValue) }

    /// `"boundary_equality / approximate_equality / …"` — the slash-separated
    /// form a tool description uses when listing legal values inline.
    static var slashSeparated: String { tokens.joined(separator: " / ") }

    /// `"boundary_equality (…), approximate_equality (…), and …"` — the
    /// glossed sentence form the `initialize` instructions use.
    static var glossedList: String {
        let described = PatternKind.allCases.map { "\($0.rawValue) (\(gloss(for: $0)))" }
        guard described.count > 1 else { return described.first ?? "" }
        return described.dropLast().joined(separator: ", ") + ", and " + (described.last ?? "")
    }

    /// The JSON Schema `enum` array for a `kind` property.
    static var jsonEnum: JSONValue { .array(tokens.map { .string($0) }) }
}
