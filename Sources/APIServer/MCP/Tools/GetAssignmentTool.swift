// APIServer/MCP/Tools/GetAssignmentTool.swift
//
// Read tool: returns one assignment's details by public ID. content:read.
// Course-scoped — the subject must be enrolled in the assignment's course
// (admins excepted). Full test-suite detail comes later via get_suite (Phase 3).

import Core
import Fluent
import Foundation

struct GetAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let slug: String
        let courseCode: String
        let isOpen: Bool
        let dueAt: String?
        let validationStatus: String?
        let deadlineOverrideActive: Bool
    }

    static let name = "get_assignment"
    static let description =
        "Get an assignment's details by its public ID: title, course code, slug, "
        + "open/closed state, due date (ISO 8601), and runner validation status."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ])
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let course = try await APICourse.find(assignment.courseID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's course could not be found.")
        }
        let formatter = ISO8601DateFormatter()
        return Output(
            publicID: assignment.publicID,
            title: assignment.title,
            slug: assignment.slug,
            courseCode: course.code,
            isOpen: assignment.isOpen,
            dueAt: assignment.dueAt.map { formatter.string(from: $0) },
            validationStatus: assignment.validationStatus,
            deadlineOverrideActive: assignment.deadlineOverrideActive ?? false
        )
    }
}
