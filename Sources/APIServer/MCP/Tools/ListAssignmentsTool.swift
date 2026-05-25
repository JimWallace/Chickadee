// APIServer/MCP/Tools/ListAssignmentsTool.swift
//
// Read tool: lists the assignments in a course, identified by course code.
// content:read scope; touches no student data, grades, or submissions.

import Core
import Fluent
import Foundation

struct ListAssignmentsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
    }

    struct Output: Encodable, Sendable {
        struct Assignment: Encodable, Sendable {
            let publicID: String
            let title: String
            let slug: String
            let isOpen: Bool
            let dueAt: String?
        }
        let courseCode: String
        let assignments: [Assignment]
    }

    static let name = "list_assignments"
    static let description =
        "List the assignments in a course, identified by course code. Returns each assignment's "
        + "public ID, title, slug, open/closed state, and due date (ISO 8601)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": .object([
                "type": .string("string"),
                "description": .string("The course code, e.g. \"CS136\"."),
            ])
        ]),
        "required": .array([.string("courseCode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": .object(["type": .string("string")]),
            "assignments": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "publicID": .object(["type": .string("string")]),
                        "title": .object(["type": .string("string")]),
                        "slug": .object(["type": .string("string")]),
                        "isOpen": .object(["type": .string("boolean")]),
                        "dueAt": .object(["type": .string("string")]),
                    ]),
                    "required": .array([
                        .string("publicID"), .string("title"), .string("slug"), .string("isOpen"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("assignments")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard
            let course = try await APICourse.query(on: context.db)
                .filter(\.$code == input.courseCode)
                .first()
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No course found with code \"\(input.courseCode)\".")
        }
        let courseID = try course.requireID()
        try await context.authorizeCourseAccess(courseID, tool: Self.name)
        let assignments = try await APIAssignment.query(on: context.db)
            .filter(\.$courseID == courseID)
            .sort(\.$title)
            .all()
        let formatter = ISO8601DateFormatter()
        let summaries = assignments.map { assignment in
            Output.Assignment(
                publicID: assignment.publicID,
                title: assignment.title,
                slug: assignment.slug,
                isOpen: assignment.isOpen,
                dueAt: assignment.dueAt.map { formatter.string(from: $0) }
            )
        }
        return Output(courseCode: input.courseCode, assignments: summaries)
    }
}
