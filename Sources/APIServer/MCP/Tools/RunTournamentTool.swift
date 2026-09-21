// APIServer/MCP/Tools/RunTournamentTool.swift
//
// Write tool: start a tournament on a tournament-kind class activity
// (docs/class-activities.md, "Tournaments") — by assignment public ID.
// content:write, course-scoped, instructor-level like `set_activity`.
//
// Snapshots every student's latest complete submission, seeds them in
// submission order, and enqueues the first round's match jobs; the rounds
// then advance on their own as results land. Reports the run so an agent can
// say how many entrants and rounds there are; it never names a student.

import Core
import Fluent
import Foundation

struct RunTournamentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// A `TournamentSchedule` token; "bracket" when absent.
        let schedule: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let tournamentID: String
        let schedule: String
        let entrantCount: Int
        let roundCount: Int
        /// "running" — the first round is enqueued; complete once every
        /// round's matches have landed.
        let status: String
        /// The bracket page, where staff read the rounds with names.
        let leaderboardPath: String
    }

    static let name = "run_tournament"
    static let description =
        "Start a tournament on a class activity whose kind keeps a bracket (aggregation \"bracket\"), "
        + "by assignment public ID. Snapshots every student's latest complete submission as the "
        + "entrants (seeded in submission order; at least two are needed), enqueues the first round's "
        + "match jobs on the native worker, and advances rounds on its own as results land; the winner "
        + "holds the seeded tournament record. schedule is \(MCPActivityProse.scheduleTokens) "
        + "(\(MCPActivityProse.scheduleSummaries)); \"bracket\" when absent. A student who resubmits "
        + "after the start plays with the snapshotted entry. A run already in progress is superseded. "
        + "Never a grade of record. Refused on any other activity kind."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "schedule": .object([
                "type": .string("string"),
                "enum": .array(TournamentSchedule.allCases.map { .string($0.rawValue) }),
                "description": .string("The pairing schedule; \"bracket\" when absent."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "tournamentID": MCPSchema.string,
            "schedule": MCPSchema.string,
            "entrantCount": MCPSchema.integer,
            "roundCount": MCPSchema.integer,
            "status": MCPSchema.string,
            "leaderboardPath": MCPSchema.string,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("tournamentID"), .string("schedule"),
            .string("entrantCount"), .string("roundCount"), .string("status"), .string("leaderboardPath"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let token =
            input.schedule?.trimmingCharacters(in: .whitespacesAndNewlines) ?? TournamentSchedule.bracket.rawValue
        guard let schedule = TournamentSchedule(rawValue: token) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "schedule must be \(MCPActivityProse.scheduleTokens).")
        }
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)
        let actor = try await context.requireEligibleSubject(tool: Self.name)
        let run: APITournamentRun
        do {
            run = try await startTournament(
                setup: setup, schedule: schedule, startedBy: actor.id, on: context.db)
        } catch let error as TournamentStartError {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: error.reason)
        }
        return Output(
            assignmentPublicID: assignment.publicID,
            tournamentID: try run.requireID().uuidString,
            schedule: run.schedule,
            entrantCount: run.entrants.count,
            roundCount: run.roundCount,
            status: run.status,
            leaderboardPath: "/testsetups/\(assignment.testSetupID)/leaderboard")
    }
}
