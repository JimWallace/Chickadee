// APIServer/Migrations/AddActivitySessionNetworks.swift
//
// The network part of the address (`ClientNetwork.prefix`) of a lab-group
// session's presenter and of each join (docs/lab-groups.md, "Presence"). Both
// optional: a row made before the columns, or a request with no readable
// address, has none, and nothing is flagged for it.

import Fluent

struct AddActivitySessionNetworks: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIActivitySession.schema)
            .field("presenter_network", .string)
            .update()
        try await database.schema(APIActivitySessionAttendance.schema)
            .field("join_network", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIActivitySessionAttendance.schema)
            .deleteField("join_network")
            .update()
        try await database.schema(APIActivitySession.schema)
            .deleteField("presenter_network")
            .update()
    }
}
