// APIServer/MCP/Tools/UpdateAssignmentTool.swift
//
// Write tool: opens or closes an assignment for student submissions.
// content:write, course-scoped. Metadata-only — no manifest change, so no
// regrade is triggered. Routes through AssignmentAuthoringService so the
// open/close semantics (validation guard, deadline override) match the
// instructor dashboard exactly. Due-date / title editing land here in a later
// phase (see docs/mcp-authoring-roadmap.md).

import Core
import Fluent
import Foundation

struct UpdateAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let isOpen: Bool
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let isOpen: Bool
        let dueAt: String?
        let validationStatus: String?
    }

    static let name = "update_assignment"
    static let description =
        "Open or close an assignment for student submissions, by its public ID. "
        + "Set isOpen=true to open (accept submissions), false to close. Opening is "
        + "refused until the assignment's runner validation has passed."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "isOpen": .object([
                "type": .string("boolean"),
                "description": .string("true to open the assignment for submissions, false to close it."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("isOpen")]),
        "additionalProperties": .bool(false),
    ])
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        do {
            try await AssignmentAuthoringService.setOpenState(assignment, open: input.isOpen, on: context.db)
        } catch AssignmentAuthoringError.validationNotPassed {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "The assignment cannot be opened until its runner validation has passed.")
        }
        let formatter = ISO8601DateFormatter()
        return Output(
            publicID: assignment.publicID,
            title: assignment.title,
            isOpen: assignment.isOpen,
            dueAt: assignment.dueAt.map { formatter.string(from: $0) },
            validationStatus: assignment.validationStatus
        )
    }
}
