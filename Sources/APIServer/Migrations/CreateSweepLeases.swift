import Fluent

/// Leader leases for the periodic sweeps (#1155): one row per sweep name;
/// the PRIMARY KEY makes the first-ever claim an atomic INSERT and the
/// conditional renew/takeover UPDATE self-arbitrating. Tiny table (one row
/// per sweep), no indexes beyond the PK.
struct CreateSweepLeases: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SweepLease.schema)
            .field("name", .string, .identifier(auto: false))
            .field("holder", .string, .required)
            .field("expires_at", .datetime, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(SweepLease.schema).delete()
    }
}
