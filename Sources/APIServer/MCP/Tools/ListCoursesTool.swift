// APIServer/MCP/Tools/ListCoursesTool.swift
//
// Read tool: lists the courses this agent may act on — the courses its account
// is enrolled in, or every course for an admin account. Lets an agent discover
// where it's allowed to read/write before calling course-scoped tools.
// content:read.

import Core
import Fluent
import Foundation

struct ListCoursesTool: ContentTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        struct Course: Encodable, Sendable {
            let code: String
            let name: String
        }
        let courses: [Course]
    }

    static let name = "list_courses"
    static let description =
        "List the courses this agent may act on: the courses its account is enrolled in "
        + "(or every course, for an admin account). Returns each course's code and name."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courses": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "code": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("code"), .string("name")]),
                ]),
            ])
        ]),
        "required": .array([.string("courses")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Students may not use the MCP interface; only instructors/admins/mcp
        // service accounts get past this.
        let user = try await context.requireEligibleSubject(tool: Self.name)

        let courses: [APICourse]
        if user.isAdmin {
            courses = try await APICourse.query(on: context.db).sort(\.$code).all()
        } else if let userID = user.id {
            let courseIDs =
                try await APICourseEnrollment.query(on: context.db)
                .filter(\.$userID == userID)
                .all()
                .map { $0.$course.id }
            courses =
                courseIDs.isEmpty
                ? []
                : try await APICourse.query(on: context.db)
                    .filter(\.$id ~~ courseIDs)
                    .sort(\.$code)
                    .all()
        } else {
            courses = []
        }

        return Output(courses: courses.map { Output.Course(code: $0.code, name: $0.name) })
    }
}
