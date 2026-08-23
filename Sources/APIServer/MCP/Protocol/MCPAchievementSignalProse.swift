// APIServer/MCP/Protocol/MCPAchievementSignalProse.swift
//
// How the achievement condition SIGNALS are spelled in agent-facing copy —
// the `initialize` instructions, the achievement tools' descriptions, and the
// units sentence beside their schema enum — derived from
// `AchievementSignal.allCases` in one place.
//
// The third instance of the same lesson. `MCPLanguageProse` was written after a
// hand-typed language list went stale; `MCPTierProse` after a hand-typed tier
// list advertised a tier that never existed. Four hand-typed signal lists were
// waiting to repeat it, and `itemsCovered` is the case that would have found
// them: an agent reading any of the four would have been told the signal does
// not exist, while the schema enum accepted it.
//
// Adding a signal requires no edit to this file and no edit to any copy that
// uses it — only the units clause below, which is per-signal by nature.

import Core

/// The condition signals, rendered for the places agent-facing copy needs them.
enum MCPAchievementSignalProse {

    /// Comma list for an inline parenthetical:
    /// `"grade, attempts, executionTimeMs, gradeJumpPercent, testPass, itemsCovered"`.
    ///
    /// Rendered without a conjunction for the same reason `MCPTierProse.oneOfList`
    /// is: these are literal values a caller matches exactly, not a sentence.
    static var commaList: String {
        AchievementSignal.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// The units and semantics clause that accompanies the schema enum.
    ///
    /// Per-signal by nature — a unit is not derivable from a case name — so it
    /// is written once here rather than at each of the tools that needs it, and
    /// the exhaustive switch means a new signal cannot silently go undescribed.
    static var unitsClause: String {
        AchievementSignal.allCases.map(unitPhrase(for:)).joined(separator: "; ")
    }

    private static func unitPhrase(for signal: AchievementSignal) -> String {
        switch signal {
        case .grade: return "grade is a percent (0–100)"
        case .attempts: return "attempts is a count"
        case .executionTimeMs: return "executionTimeMs is milliseconds"
        case .gradeJumpPercent: return "gradeJumpPercent is percentage points"
        case .testPass: return "testPass checks a named test (set testRef, not value)"
        case .itemsCovered:
            return
                "itemsCovered is a count of DISTINCT suite items the whole class has passed "
                + "between them, optionally scoped to one suite section with sectionRef "
                + "(classWide goals only)"
        }
    }
}
