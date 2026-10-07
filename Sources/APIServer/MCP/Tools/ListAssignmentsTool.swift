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
            /// Three-state visibility: "closed" | "preview" | "open".
            let visibility: String
            let dueAt: String?
            let startsAt: String?
        }
        let courseCode: String
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let assignments: [Assignment]
    }

    static let name = "list_assignments"
    static let description =
        "List the assignments in a course, identified by course code. Returns each assignment's "
        + "public ID, title, slug, visibility (closed/preview/open), the derived isOpen flag, due "
        + "date (ISO 8601), and scheduled open date (ISO 8601, if any)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode
        ]),
        "required": .array([.string("courseCode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "assignments": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "publicID": MCPSchema.string,
                        "title": MCPSchema.string,
                        "slug": MCPSchema.string,
                        "isOpen": MCPSchema.boolean,
                        "visibility": .object([
                            "type": .string("string"),
                            "enum": MCPEnumProse<AssignmentVisibility>.jsonEnum,
                        ]),
                        "dueAt": MCPSchema.string,
                        "startsAt": MCPSchema.string,
                    ]),
                    "required": .array([
                        .string("publicID"), .string("title"), .string("slug"), .string("isOpen"),
                        .string("visibility"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("courseKey"), .string("assignments")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourse(code: input.courseCode, context: context)
        let courseID = try course.requireID()
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
                visibility: assignment.visibility.rawValue,
                dueAt: assignment.dueAt.map { formatter.string(from: $0) },
                startsAt: assignment.startsAt.map { formatter.string(from: $0) }
            )
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            assignments: summaries)
    }
}
