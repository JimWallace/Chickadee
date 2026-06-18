// APIServer/MCP/Tools/UpdateAchievementsTool.swift
//
// Write tool: replace an assignment's composable Achievements list by public ID.
// content:write, course-scoped.  Mirrors `PUT /instructor/:assignmentID
// /achievements` and drives the same `AchievementsEditing.apply` path the web
// editor uses, so the same validation runs (non-empty name, known scope, 0–100
// class share / percent values, non-negative points, valid record dimension,
// a testPass condition needing a filename).
//
// The list is REPLACED wholesale — send the complete desired set, not a delta;
// an empty array clears every achievement.  Saving marks the built-in defaults
// as curated, so they no longer merge into the list on read.
//
// Unlike the other content-edit tools, achievements are SERVER-EVALUATED and
// DISPLAY-ONLY: they never change what the suite grades, so this tool does NOT
// re-run validation, re-queue submissions for regrade, or close the assignment.

import Core
import Fluent
import Foundation

struct UpdateAchievementsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// The full desired achievements list.  Replaces the existing list
        /// wholesale; send `[]` to clear every achievement.
        let achievements: [AchievementRow]
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let achievements: [AchievementRow]
    }

    static let name = "update_achievements"
    static let description =
        "Replace an assignment's achievements (the instructor-authored awards shown to students) by "
        + "public ID. Provide the full desired list; it is replaced wholesale, not merged — send [] to "
        + "clear every achievement. Each row needs a `name` and a `scope`: individual (a per-student "
        + "badge), classWide (a collaborative class goal — set classPercent 0–100 and points ≥ 0), or "
        + "record (a single-holder competitive title — set recordDimension). Conditions are typed "
        + "predicates over a submission's signals (grade/gradeJumpPercent 0–100, attempts, "
        + "executionTimeMs, testPass with a testRef filename) combined with `match` (all/any). Use "
        + "get_achievements first to read the current list (which includes the built-in defaults until "
        + "you first save). Saving marks the built-ins curated, so removed built-ins stay removed. "
        + "Achievements are server-evaluated and display-only: this does NOT re-validate, re-grade "
        + "submissions, or close the assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "achievements": .object([
                "type": .string("array"),
                "description": .string(
                    "The full desired achievements list; replaces the existing list. Send [] to clear."),
                "items": achievementRowSchema,
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("achievements")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "achievements": .object([
                "type": .string("array"),
                "items": achievementRowSchema,
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("achievements")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)

        let rows: [AchievementRow]
        do {
            rows = try await AchievementsEditing.apply(
                rows: input.achievements, setup: setup, on: context.db)
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        }

        return Output(assignmentPublicID: assignment.publicID, achievements: rows)
    }
}
