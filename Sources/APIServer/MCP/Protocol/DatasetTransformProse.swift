// APIServer/MCP/Protocol/DatasetTransformProse.swift
//
// How the dataset transform kinds are SPELLED in agent-facing copy, derived
// from `DatasetTransform.Kind.allCases` in one place.
//
// Same reasoning as `MCPLanguageProse`, applied before the list can go stale
// rather than after: a hand-typed kind list in a tool description is prose, and
// prose is the surface no compiler and no `allCases` test reaches. The language
// list had to be fixed twice — the second time because the first fix repaired
// the string it was looking at instead of the class — so this one was derived
// from the first kind on.
//
// A new kind needs no edit to any tool description. It needs one gloss line
// in `gloss(_:)`, which an exhaustive switch makes the compiler ask for.

import Core

enum DatasetTransformProse {

    /// Each kind as its wire token and what it does, one clause per kind in
    /// `allCases` order.
    static var glossary: String {
        DatasetTransform.Kind.allCases.map { "\"\($0.rawValue)\" \(gloss($0))" }.joined(separator: "; ")
    }

    private static func gloss(_ kind: DatasetTransform.Kind) -> String {
        switch kind {
        case .missingValues:
            return "blanks the chosen cells"
        case .formatNoise:
            return "writes the chosen cells with a space on each side or in another letter case, never as "
                + "another value (missing-value markers such as NA stay as they are); a check on such a "
                + "column should compare trimmed, case-insensitive text"
        }
    }
}
