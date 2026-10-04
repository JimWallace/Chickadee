// APIServer/MCP/Tools/ListCoursesTool.swift
//
// Read tool: lists the courses this agent may act on — the non-archived
// courses its account is enrolled in, for every role (admins included). Lets
// an agent discover where it's allowed to read/write before calling
// course-scoped tools. content:read.

import Core
import Fluent
import Foundation

struct ListCoursesTool: ContentTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        struct Course: Encodable, Sendable {
            let code: String
            let name: String
            /// "Fall 2026", or nil when the course records no term.
            let term: String?
            /// The value to pass as `courseCode` to name exactly this course.
            let key: String
        }
        let courses: [Course]
    }

    static let name = "list_courses"
    static let description =
        "List the courses this agent may act on: the courses its account is enrolled in. "
        + "This is the agent's full reach — no role widens it; enrolling the account in a course "
        + "adds it. Returns each course's code, name, term, and key — pass the key as "
        + "courseCode when several offerings share a code."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courses": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "code": MCPSchema.string,
                        "name": MCPSchema.string,
                        "term": .object(["type": .array([.string("string"), .string("null")])]),
                        "key": MCPSchema.string,
                    ]),
                    "required": .array([.string("code"), .string("name"), .string("key")]),
                ]),
            ])
        ]),
        "required": .array([.string("courses")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Students may not use the MCP interface; only instructors/admins/mcp
        // service accounts get past this.
        let user = try await context.requireEligibleSubject()
        guard let userID = user.id else { return Output(courses: []) }
        let courses = try await enrolledCourses(for: userID, on: context.db)
        return Output(
            courses: courses.map {
                Output.Course(code: $0.code, name: $0.name, term: $0.term?.displayName, key: $0.urlKey)
            })
    }
}
