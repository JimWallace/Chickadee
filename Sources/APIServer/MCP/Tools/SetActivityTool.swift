// APIServer/MCP/Tools/SetActivityTool.swift
//
// Write tool: make an assignment a class activity (a leaderboard challenge),
// change its leaderboard visibility, or turn it back into an ordinary
// assignment — by assignment public ID. content:write, course-scoped.
//
// The kind is locked once a student has submitted, the same rule as the
// language; the leaderboard's visibility may change at any time. Both
// surfaces (this tool and the web edit page) call `ActivityAuthoring`, so the
// lock and the seeded defaults are enforced once.

import Core
import Fluent
import Foundation

struct SetActivityTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// An `ActivityKind` token, or "none" to make it an ordinary assignment.
        let kind: String
        /// "hidden" (default) or "visible". Ignored with kind "none".
        let leaderboardVisibility: String?
        /// For a kind that stages an opponent: the support file to stage as
        /// the bot. Absent keeps the stored file when the kind is unchanged;
        /// "" clears it. Refused on a kind with no opponent. (`var` so the
        /// memberwise init defaults it, as an absent wire field does.)
        var opponentFile: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The stored kind, or "none".
        let kind: String
        /// The stored visibility, or null for an ordinary assignment.
        let leaderboardVisibility: String?
        /// The student-facing leaderboard path, null for an ordinary assignment.
        let leaderboardPath: String?
        /// True when a `highestMetric` record achievement is on the manifest.
        let recordAchievementSeeded: Bool
        /// The kind's opponent source (\(MCPActivityProse.opponentSourceTokens)),
        /// null for an ordinary assignment.
        var opponentSource: String?
        /// The support file staged as the opponent; null when the kind has no
        /// opponent or none is chosen yet.
        var opponentFile: String?

        private enum CodingKeys: String, CodingKey {
            case assignmentPublicID, kind, leaderboardVisibility, leaderboardPath
            case recordAchievementSeeded, opponentSource, opponentFile
        }

        /// The two opponent keys are always present — explicitly null when
        /// there is no opponent — so an agent reading the result can tell
        /// "no opponent" from "a server that predates the field".
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(assignmentPublicID, forKey: .assignmentPublicID)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(leaderboardVisibility, forKey: .leaderboardVisibility)
            try c.encodeIfPresent(leaderboardPath, forKey: .leaderboardPath)
            try c.encode(recordAchievementSeeded, forKey: .recordAchievementSeeded)
            try c.encode(opponentSource, forKey: .opponentSource)
            try c.encode(opponentFile, forKey: .opponentFile)
        }
    }

    /// The wire value for "no activity"; shared with the web select.
    static let noActivityChoice = "none"

    static let name = "set_activity"
    static let description =
        "Make an assignment a class activity by its public ID, or change its leaderboard "
        + "visibility, or clear it. kind is \(MCPActivityProse.tokens), or \"none\" for an ordinary "
        + "assignment. Kinds: \(MCPActivityProse.summaries). Every kind ranks students on the "
        + "unclamped `metric` field a test script prints in its JSON footer beside `score` "
        + "(highest first; a script whose lower is better reports the negation), so author one "
        + "suite entry whose script reports it. Setting a kind seeds a record achievement on the "
        + "highest metric. The kind is LOCKED once any student has submitted — clone the assignment "
        + "instead — but leaderboardVisibility (\"hidden\", the default, or \"visible\") and "
        + "opponentFile may change at any time. A kind whose opponent source is \"supportFile\" "
        + "plays each submission against a bot: upload the bot as a support file (graderOnly to hide "
        + "its source), name it in opponentFile, and the native worker stages it in the directory "
        + "the match script reads from CHICKADEE_OPPONENT_DIR, with a per-match seed in "
        + "CHICKADEE_MATCH_SEED. Such a kind needs worker grading and is refused on a browser-graded "
        + "assignment. opponentFile absent keeps the stored file; \"\" clears it. No regrade or "
        + "close. Read the current state from get_assignment; get_server_info lists the kinds with "
        + "their opponent sources."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "kind": .object([
                "type": .string("string"),
                "enum": .array(
                    ActivityKind.allCases.map { .string($0.rawValue) } + [.string(noActivityChoice)]),
                "description": .string(
                    "\(MCPActivityProse.quotedTokenAlternatives) | \"none\" (an ordinary assignment)."),
            ]),
            "leaderboardVisibility": .object([
                "type": .string("string"),
                "enum": .array(LeaderboardVisibility.allCases.map { .string($0.rawValue) }),
                "description": .string(
                    "Whether students may open the leaderboard; \"hidden\" by default. Staff always can."),
            ]),
            "opponentFile": .object([
                "type": .string("string"),
                "description": .string(
                    "The support file staged as the opponent, for a kind whose opponent source is "
                        + "\"supportFile\". Absent keeps the stored file; \"\" clears it."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("kind")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "kind": MCPSchema.string,
            "leaderboardVisibility": MCPSchema.string,
            "leaderboardPath": MCPSchema.string,
            "recordAchievementSeeded": MCPSchema.boolean,
            "opponentSource": .object([
                "type": .string("string"),
                "enum": .array(ActivityOpponentSource.allCases.map { .string($0.rawValue) }),
            ]),
            "opponentFile": MCPSchema.string,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("kind"), .string("recordAchievementSeeded"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let kindToken = input.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let activity: ClassActivity?
        if kindToken == Self.noActivityChoice {
            activity = nil
        } else {
            guard let kind = ActivityKind(rawValue: kindToken) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "kind must be \(MCPActivityProse.tokens), or \"none\".")
            }
            let visibilityToken =
                input.leaderboardVisibility?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? LeaderboardVisibility.hidden.rawValue
            guard let visibility = LeaderboardVisibility(rawValue: visibilityToken) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "leaderboardVisibility must be \"hidden\" or \"visible\".")
            }
            activity = ClassActivity(kind: kind, leaderboardVisibility: visibility)
        }
        // A lifecycle setting — instructor-level, like set_submission_mode.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)
        let requested = activity.map { block in
            block.withOpponentFile(
                Self.resolvedOpponentFile(
                    input: input.opponentFile, kind: block.kind,
                    current: currentManifestActivity(setup.manifest)))
        }
        do {
            try await ActivityAuthoring.setActivity(setup: setup, to: requested, on: context.db)
        } catch let error as AppError {
            // Surface the lock as an arguments error so an agent reads a
            // fixable message rather than a 400.
            throw MCPToolError.invalidArguments(tool: Self.name, detail: error.reason)
        }
        let stored = setup.decodedManifest()
        return Output(
            assignmentPublicID: assignment.publicID,
            kind: stored?.activity?.kind.rawValue ?? Self.noActivityChoice,
            leaderboardVisibility: stored?.activity?.leaderboardVisibility.rawValue,
            leaderboardPath: stored?.activity.map { _ in
                "/testsetups/\(assignment.testSetupID)/leaderboard"
            },
            recordAchievementSeeded: stored?.achievements
                .contains { $0.recordDimension == .highestMetric } ?? false,
            opponentSource: stored?.activity?.kind.opponentSource.rawValue,
            opponentFile: stored?.activity?.opponentFile)
    }

    /// The opponent file the call means: an explicit value as given (trimmed;
    /// "" clears), or, when absent, the stored file carried forward as long as
    /// the kind is unchanged — so a visibility-only call cannot drop the bot.
    /// A kind change starts from none, since another kind's bot means nothing.
    static func resolvedOpponentFile(
        input: String?, kind: ActivityKind, current: ClassActivity?
    ) -> String? {
        if let input {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return current?.kind == kind ? current?.opponentFile : nil
    }
}
