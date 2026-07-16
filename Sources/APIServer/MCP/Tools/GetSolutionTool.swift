// APIServer/MCP/Tools/GetSolutionTool.swift
//
// Read tool: returns an assignment's reference SOLUTION notebook (the
// instructor's answer key used to validate the suite) as structured .ipynb
// JSON, by assignment public ID. content:read, course-scoped.
//
// The solution is resolved from the assignment's linked validation submission
// (or the most recent `kind == .validation` submission for the setup) via the
// shared `loadExistingSolution` resolver. It is instructor-authored content —
// the resolver only ever returns a validation/solution submission, never a
// student submission — so this stays consistent with the MCP server's "never
// exposes student submissions" guarantee.
//
// Use this before update_solution to see the current answer key (e.g. to check
// whether it computes a per-student personalized answer rather than hardcoding
// one), mirroring how get_notebook precedes update_notebook.

import Core
import Fluent
import Foundation

struct GetSolutionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let filename: String
        let cellCount: Int
        let notebook: JSONValue
    }

    static let name = "get_solution"
    static let description =
        "Get an assignment's reference SOLUTION notebook (the instructor's answer key used to validate "
        + "the test suite) as .ipynb JSON, by assignment public ID. This is instructor-authored content "
        + "resolved from the assignment's validation submission — never a student submission. Returns the "
        + "notebook, its filename, and a cell count. Read-only; use it to inspect the solution (for "
        + "example to confirm it computes a personalized answer) before editing it with update_solution."
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
            "filename": MCPSchema.string,
            "cellCount": MCPSchema.integer,
            "notebook": .object(["type": .string("object")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("filename"), .string("cellCount"),
            .string("notebook"),
        ]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let assignment = try await context.authorizedAssignment(
            publicID: input.assignmentPublicID, tool: Self.name)

        guard let solution = try await loadExistingSolution(assignment: assignment, on: context.db)
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail:
                    "This assignment has no solution notebook on file. Upload one in the editor, or set "
                    + "one with update_solution.")
        }

        let notebook: JSONValue
        do {
            notebook = try JSONDecoder().decode(JSONValue.self, from: solution.data)
        } catch {
            throw MCPToolError.executionFailed(
                tool: Self.name,
                detail: "The stored solution (\(solution.filename)) is not valid notebook JSON.")
        }

        return Output(
            assignmentPublicID: assignment.publicID,
            filename: solution.filename,
            cellCount: notebookCellCount(notebook),
            notebook: notebook)
    }
}
