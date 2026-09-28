// APIServer/Migrations/AddLTIMembershipsColumn.swift
//
// `courses.lti_memberships_url`, the NRPS membership URL from a launch
// (docs/lti-1-3.md slice 5). Nil on every existing row: the roster check keeps
// reading the Valence classlist.

import Fluent

struct AddLTIMembershipsColumn: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses").field("lti_memberships_url", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses").deleteField("lti_memberships_url").update()
    }
}
