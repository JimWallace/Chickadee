// APIServer/Migrations/AddCourseMCPInstructions.swift
//
// Per-course authoring guidance for MCP agents.  Instructors edit it on the
// instructor MCP panel; the content MCP server appends it to the `initialize`
// instructions for accounts with authoring authority in the course.  Nil means
// the course has no custom guidance and agents see only the house guide.

import Fluent

struct AddCourseMCPInstructions: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("mcp_instructions", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("mcp_instructions")
            .update()
    }
}
