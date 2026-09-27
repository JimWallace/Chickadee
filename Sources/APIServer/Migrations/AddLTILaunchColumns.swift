// APIServer/Migrations/AddLTILaunchColumns.swift
//
// The two nullable additions slice 2 of docs/lti-1-3.md needs on existing
// tables. Both are nil on every existing row, which is the pre-LTI behaviour:
//
// - `courses.lti_platform_id` + `courses.lti_context_id`: the LMS course a
//   Chickadee course is bound to. Nil = not bound.
// - `lti_platforms.trust_username`: whether a launch may link to an existing
//   account by the platform's username. Nil = no, the safe default.

import Fluent

struct AddLTILaunchColumns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One column per update: SQLite alters one column per statement.
        try await database.schema("courses").field("lti_platform_id", .uuid).update()
        try await database.schema("courses").field("lti_context_id", .string).update()
        try await database.schema(APILTIPlatform.schema)
            .field("trust_username", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APILTIPlatform.schema)
            .deleteField("trust_username")
            .update()
        try await database.schema("courses").deleteField("lti_context_id").update()
        try await database.schema("courses").deleteField("lti_platform_id").update()
    }
}
