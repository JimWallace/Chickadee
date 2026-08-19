// APIServer/MCP/Tools/GetAchievementsTool.swift
//
// Read tool: returns an assignment's composable Achievements list by public ID
// — the instructor-authored badges, class goals, and competitive records shown
// to students.  content:read, course-scoped.  Mirrors
// `GET /instructor/:assignmentID/achievements` and runs the shared
// `AchievementsEditing` conversion, so until the instructor first curates the
// list the built-in defaults (Ace, Rally, Tenacious, Swift, Pathfinder,
// Trailblazer, Fastest, Minimalist) are merged in as editable rows.

import Core
import Fluent
import Foundation

struct GetAchievementsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let achievements: [AchievementRow]
    }

    static let name = "get_achievements"
    static let description =
        "Get an assignment's achievements (the instructor-authored awards shown to students) by public "
        + "ID. Each row has a scope (individual badge / classWide collaborative goal / single-holder "
        + "record), a list of conditions over a submission's graded signals ("
        + MCPAchievementSignalProse.commaList + ") combined with `match` (all/any), and the "
        + "scope's reward parameters (classPercent + points for a class goal, recordDimension for a "
        + "record). Until the instructor first curates the list, the built-in defaults are returned as "
        + "editable rows. Read-only — use it to inspect achievements before editing with "
        + "update_achievements. Achievements are server-evaluated and display-only: they never change "
        + "what the suite grades."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "achievements": .object([
                "type": .string("array"),
                "items": achievementRowSchema,
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("achievements")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)
        return Output(
            assignmentPublicID: assignment.publicID,
            achievements: AchievementsEditing.rows(fromManifest: setup.manifest))
    }
}

/// The JSON Schema for one `AchievementRow`, shared by get_achievements'
/// output and update_achievements' input so the agent sees one row shape.
let achievementRowSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "id": .object([
            "type": .string("string"),
            "description": .string(
                "Stable row id; omit on a new row and the server assigns one."),
        ]),
        "name": .object([
            "type": .string("string"),
            "description": .string("Student-facing label; also the badge/title caption."),
        ]),
        "detail": .object([
            "type": .string("string"),
            "description": .string("Optional longer \"how to earn this\" description."),
        ]),
        "scope": .object([
            "type": .string("string"),
            "enum": .array([
                .string("individual"), .string("classWide"), .string("record"),
            ]),
            "description": .string(
                "individual = a per-student badge; classWide = a collaborative class goal "
                    + "(needs classPercent + points); record = a single-holder competitive title "
                    + "(needs recordDimension)."),
        ]),
        "match": .object([
            "type": .string("string"),
            "enum": .array([.string("all"), .string("any")]),
            "description": .string("Whether all conditions (AND) or any (OR) must hold. Default all."),
        ]),
        "conditions": .object([
            "type": .string("array"),
            "description": .string(
                "Typed predicates over a submission's graded signals. Empty = vacuously satisfied "
                    + "(records rank rather than gate, so usually empty)."),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "signal": .object([
                        "type": .string("string"),
                        "enum": .array(AchievementSignalValues.all.map(JSONValue.string)),
                        "description": .string(MCPAchievementSignalProse.unitsClause + "."),
                    ]),
                    "comparator": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("atLeast"), .string("atMost"), .string("equals"),
                        ]),
                    ]),
                    "value": .object([
                        "type": .string("number"),
                        "description": .string("Threshold the signal is compared against; ignored for testPass."),
                    ]),
                    "testRef": .object([
                        "type": .string("string"),
                        "description": .string(
                            "For a testPass condition: the test that must pass, by script filename "
                                + "(e.g. secrettest_x.py) or display name. Validated against the suite on save."),
                    ]),
                    "sectionRef": .object([
                        "type": .string("string"),
                        "description": .string(
                            "For an itemsCovered condition: the suite section whose items the class "
                                + "union is counted over, by section name or id (a name is resolved "
                                + "to its id on save). Omit to count every test in the suite. "
                                + "Validated against the suite on save."),
                    ]),
                ]),
                "required": .array([.string("signal"), .string("comparator")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
        "classPercent": .object([
            "type": .string("number"),
            "description": .string("classWide only: share of the class (0–100) that must satisfy the conditions."),
        ]),
        "points": .object([
            "type": .string("integer"),
            "description": .string("classWide only: bonus points (≥ 0) awarded when the goal is met."),
        ]),
        "recordDimension": .object([
            "type": .string("string"),
            "enum": .array([
                .string("firstToSolve"), .string("firstToSubmit"), .string("fastest"),
                .string("shortest"),
            ]),
            "description": .string(
                "record only: the dimension students are ranked on. firstToSolve = first to 100%; "
                    + "firstToSubmit = first submission of any kind; fastest = lowest execution time "
                    + "at 100%; shortest = FEWEST ATTEMPTS to reach 100% (a legacy name — it does not "
                    + "measure solution length)."),
        ]),
    ]),
    "required": .array([.string("name"), .string("scope")]),
    "additionalProperties": .bool(false),
])
