// APIServer/MCP/Tools/SetGradingModeTool.swift
//
// Write tool: set how an assignment's submissions are graded — "worker" (native
// runner) or "browser" (in the student's browser, on a xeus kernel) — by assignment public ID.
// content:write, course-scoped.
//
// gradingMode lives in the test setup's manifest, not on the assignment row.
// get_assignment surfaces it; create_assignment sets it from the declared type,
// and this is the direct setter, bounded by the type (an Assignment refuses
// "browser", docs/assignment-types.md). Changing the grading path doesn't change
// what the tests check, so — matching the web setup editor — it does NOT
// re-grade existing submissions, re-run validation, or close the assignment.

import Core
import Fluent
import Foundation

struct SetGradingModeTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// "browser" or "worker".
        let gradingMode: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let gradingMode: String
    }

    static let name = "set_grading_mode"
    static let description =
        "Set how an assignment's submissions are graded by its public ID: \"worker\" (graded by the "
        + "native runner) or \"browser\" (graded in the student's browser on a xeus kernel). This changes only the grading "
        + "path, not the tests, so it does not re-grade existing submissions, re-run validation, or "
        + "change the open/closed state (matching the web setup editor). Read the current mode from "
        + "get_assignment. The assignment's declared type bounds the choice: an assignment (type "
        + "\"assignment\") refuses \"browser\", because browser grading would deliver its release and "
        + "secret tests to every student; change the type with update_assignment first. A \"browser\" "
        + "grade is a participation grade: the student's browser reports it and the server keeps it "
        + "unchecked, so choose \"worker\" for work whose grade must be correct."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "gradingMode": .object([
                "type": .string("string"),
                "enum": MCPEnumProse<GradingMode>.jsonEnum,
                "description": .string(
                    "\"worker\" (native runner) or \"browser\" (in the student's browser, on a xeus kernel)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("gradingMode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "gradingMode": MCPSchema.string,
        ]),
        "required": .array([.string("assignmentPublicID"), .string("gradingMode")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let mode = input.gradingMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try MCPEnumProse<GradingMode>.parse(mode, field: "gradingMode")
        // Grading mode (worker vs browser) is a lifecycle setting — instructor-level (#417).
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .instructor)
        // Surface a coherence violation as an arguments error, so an agent
        // reads a fixable message rather than a 400 (the shared helper's own
        // guard backstops any path that skips this). The rules are
        // `ManifestCoherence`'s; `author_script` and `set_activity` refuse the
        // same combinations from the other direction.
        if let violation = ManifestCoherence.violation(
            for: assignment.declaredAssignmentType, introducedBy: { $0.gradingMode = parsed }, in: setup.manifest)
        {
            throw MCPToolError.invalidArguments(detail: violation)
        }
        let effective = try await setManifestGradingMode(setup: setup, to: mode, on: context.db)
        return Output(assignmentPublicID: assignment.publicID, gradingMode: effective)
    }
}
