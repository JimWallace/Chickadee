// APIServer/MCP/Tools/SetGradingModeTool.swift
//
// Write tool: set how an assignment's submissions are graded — "worker" (native
// runner) or "browser" (in-browser Pyodide) — by assignment public ID.
// content:write, course-scoped.
//
// gradingMode lives in the test setup's manifest, not on the assignment row.
// get_assignment surfaces it and set_assignment_course_section changes it as a
// side-effect of adopting a course section's default; this is the direct setter
// for an assignment that isn't in a section (or whose mode you want to change
// without moving it). Changing the grading path doesn't change what the tests
// check, so — matching set_assignment_course_section and the web setup editor — it does
// NOT re-grade existing submissions, re-run validation, or close the assignment.

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
        + "native runner) or \"browser\" (graded in-browser via Pyodide). This changes only the grading "
        + "path, not the tests, so it does not re-grade existing submissions, re-run validation, or "
        + "change the open/closed state (matching set_assignment_course_section and the web setup editor). Read "
        + "the current mode from get_assignment. To make a whole course section default to a mode, use "
        + "create_course_section / rename_course_section instead."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "gradingMode": .object([
                "type": .string("string"),
                "enum": .array([.string("browser"), .string("worker")]),
                "description": .string("\"worker\" (native runner) or \"browser\" (in-browser Pyodide)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("gradingMode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "gradingMode": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("gradingMode")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let mode = input.gradingMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == "browser" || mode == "worker" else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "gradingMode must be \"browser\" or \"worker\".")
        }
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }
        let effective = try await setManifestGradingMode(setup: setup, to: mode, on: context.db)
        return Output(assignmentPublicID: assignment.publicID, gradingMode: effective)
    }
}
