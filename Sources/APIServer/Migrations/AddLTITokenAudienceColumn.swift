// APIServer/Migrations/AddLTITokenAudienceColumn.swift
//
// `lti_platforms.token_audience`: the audience of the JWT the tool signs to
// get an AGS or NRPS access token (docs/lti-1-3.md "Platform registration").
// Nil on every existing row: the audience stays the access token URL.

import Fluent

struct AddLTITokenAudienceColumn: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lti_platforms").field("token_audience", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lti_platforms").deleteField("token_audience").update()
    }
}
