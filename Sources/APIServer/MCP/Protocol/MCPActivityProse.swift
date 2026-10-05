// APIServer/MCP/Protocol/MCPActivityProse.swift
//
// The class-activity kinds, rendered for agent-facing copy — the same
// discipline as `MCPLanguageProse`, for the same reason: a hand-typed list of
// kinds is correct until the next kind ships, and then it is silently short.
// No tool description or schema holds a kind name; each interpolates one of
// these, and `MCPActivityCoverageTests` fails on a list that stops short.

import Core

enum MCPActivityProse {

    /// `"Beat the instructor or Best metric"` — for a sentence about what the
    /// system supports.
    static var displayNames: String {
        LanguageProse.list(ActivityKind.allCases.map(\.displayName))
    }

    /// `"beatTheInstructor or bestMetric"` — the wire tokens a caller passes.
    static var tokens: String { MCPEnumProse<ActivityKind>.orList }

    /// `"\"beatTheInstructor\" | \"bestMetric\""` — a field description's union.
    static var quotedTokenAlternatives: String { MCPEnumProse<ActivityKind>.quotedUnion }

    /// One clause per kind: `"beatTheInstructor — …; bestMetric — …"`.
    static var summaries: String {
        ActivityKind.allCases.map { "\($0.rawValue) — \($0.summary)" }.joined(separator: "; ")
    }

    /// One clause per aggregation: how it ranks the class and which record
    /// `set_activity` seeds for it. Derived per case, so an aggregation that
    /// ranks on something other than `metric` cannot be described as if it
    /// did (#2190).
    static var aggregationSummaries: String {
        ActivityAggregation.allCases.map { "\($0.rawValue) — \(summary(of: $0))" }.joined(separator: "; ")
    }

    private static func summary(of aggregation: ActivityAggregation) -> String {
        switch aggregation {
        case .leaderboard:
            return
                "ranks students on the unclamped `metric` field a test script prints in its JSON footer "
                + "beside `score` (highest first; a script whose lower is better reports the negation), "
                + "so author one suite entry whose script reports it, and seeds a record achievement on "
                + "the highest metric"
        case .standings:
            return
                "ranks students by average match score, then wins, over each student's latest "
                + "submission, and seeds the standings-leader record"
        case .bracket:
            return "shows a tournament's rounds and its winner, and seeds the tournament-winner record"
        case .union:
            return
                "reads every match as a kill for the tester and as a fault against the tested code, "
                + "and seeds no record"
        }
    }

    /// `"none or supportFile"` — the opponent-source tokens a payload reports.
    static var opponentSourceTokens: String { MCPEnumProse<ActivityOpponentSource>.orList }

    /// `"bracket or swiss"` — the tournament schedules `run_tournament` takes.
    static var scheduleTokens: String { MCPEnumProse<TournamentSchedule>.orList }

    /// One clause per schedule: `"bracket — …; swiss — …"`.
    static var scheduleSummaries: String {
        TournamentSchedule.allCases.map { "\($0.rawValue) — \($0.summary)" }.joined(separator: "; ")
    }
}

/// One activity kind's facts, as reported by `get_server_info`. Every field is
/// derived from `ActivityKind`, so the payload cannot omit a kind or describe
/// one the save would refuse.
struct MCPActivityKindCapability: Encodable, Sendable, Equatable {
    /// The wire token an agent passes to `set_activity`.
    let name: String
    let displayName: String
    /// What the kind does and where its ranking number comes from.
    let summary: String
    /// How the class's results combine: the kind's `ActivityAggregation` token
    /// (`leaderboard`, `standings`, `bracket` or `union`). The schema's enum is
    /// derived from the same cases, so the two cannot disagree.
    let aggregation: String
    /// What is staged beside the submission when the script runs: "none", or
    /// "supportFile" for a kind that plays a bundled bot (which then needs
    /// worker grading and an `opponentFile`).
    let opponentSource: String

    static var all: [MCPActivityKindCapability] {
        ActivityKind.allCases.map { kind in
            MCPActivityKindCapability(
                name: kind.rawValue,
                displayName: kind.displayName,
                summary: kind.summary,
                aggregation: kind.aggregation.rawValue,
                opponentSource: kind.opponentSource.rawValue)
        }
    }
}
