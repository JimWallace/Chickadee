// APIServer/MCP/Tools/UpdateAssignmentTitleTool.swift
//
// Write tool: updates an assignment's display title.  content:write scope.
// The smallest meaningful authoring mutation — reuses the existing
// assignmentByPublicID lookup and the standard save path.

import Core
import Fluent
import Foundation

struct UpdateAssignmentTitleTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let title: String
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let slug: String
    }

    static let name = "update_assignment_title"
    static let description =
        "Update the display title of an assignment, identified by its public ID. "
        + "Returns the updated assignment summary."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("The new display title (non-empty)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("title")]),
        "additionalProperties": .bool(false),
    ])
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let trimmed = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "title must not be empty.")
        }
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        assignment.title = trimmed
        try await assignment.save(on: context.db)
        return Output(publicID: assignment.publicID, title: assignment.title, slug: assignment.slug)
    }
}
