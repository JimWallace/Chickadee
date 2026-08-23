// APIServer/MCP/Protocol/DatasetTransformProse.swift
//
// How the dataset transform kinds are SPELLED in agent-facing copy, derived
// from `DatasetTransform.Kind.allCases` in one place.
//
// Same reasoning as `MCPLanguageProse`, applied before the list can go stale
// rather than after: a hand-typed kind list in a tool description is prose, and
// prose is the surface no compiler and no `allCases` test reaches. The language
// list had to be fixed twice — the second time because the first fix repaired
// the string it was looking at instead of the class — so this one starts
// derived while there is exactly one kind and nothing to get wrong yet.
//
// A second transform kind needs no edit to any tool description.

import Core

enum DatasetTransformProse {

    /// The kinds as a wire-token list for a schema description:
    /// `"missingValues"`, and with a second kind `"missingValues" or "x"`.
    static var kinds: String {
        let quoted = DatasetTransform.Kind.allCases.map { "\"\($0.rawValue)\"" }
        guard let last = quoted.last else { return "" }
        guard quoted.count > 1 else { return last }
        return quoted.dropLast().joined(separator: ", ") + " or " + last
    }
}
