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
    static var tokens: String {
        LanguageProse.list(ActivityKind.allCases.map(\.rawValue))
    }

    /// `"\"beatTheInstructor\" | \"bestMetric\""` — a field description's union.
    static var quotedTokenAlternatives: String {
        ActivityKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | ")
    }

    /// One clause per kind: `"beatTheInstructor — …; bestMetric — …"`.
    static var summaries: String {
        ActivityKind.allCases.map { "\($0.rawValue) — \($0.summary)" }.joined(separator: "; ")
    }

    /// `"none or supportFile"` — the opponent-source tokens a payload reports.
    static var opponentSourceTokens: String {
        LanguageProse.list(ActivityOpponentSource.allCases.map(\.rawValue))
    }

    /// `"bracket or swiss"` — the tournament schedules `run_tournament` takes.
    static var scheduleTokens: String {
        LanguageProse.list(TournamentSchedule.allCases.map(\.rawValue))
    }

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
    /// How the class's results combine. Reports "leaderboard" for every kind
    /// with a ranking page (`aggregatesToLeaderboard`), which is all of them;
    /// `SetActivityToolTests.serverInfoListsEveryKind` pins that value, so
    /// the finer `ActivityAggregation` axis (standings, bracket) is not yet
    /// reported here.
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
                aggregation: kind.aggregatesToLeaderboard ? "leaderboard" : "standings",
                opponentSource: kind.opponentSource.rawValue)
        }
    }
}
