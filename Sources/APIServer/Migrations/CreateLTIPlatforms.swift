// APIServer/Migrations/CreateLTIPlatforms.swift
//
// LTI 1.3 platform registrations (docs/lti-1-3.md). New table, no foreign
// keys, so no ordering constraint. `(issuer, client_id)` is unique: a launch
// names both, and two rows for one pair would make the lookup ambiguous.
//
// Two columns were folded in from later migrations in the fourth round
// (#1806): `trust_username` (AddLTILaunchColumns) and `token_audience`
// (AddLTITokenAudienceColumn).

import Fluent

struct CreateLTIPlatforms: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APILTIPlatform.schema)
            .id()
            .field("issuer", .string, .required)
            .field("client_id", .string, .required)
            .field("deployment_ids", .string, .required)
            .field("auth_login_url", .string, .required)
            .field("access_token_url", .string, .required)
            .field("jwks_url", .string, .required)
            .field("display_name", .string, .required)
            .field("enabled", .bool, .required)
            .field("created_at", .datetime, .required)
            // Whether a launch from this platform may claim a local account by
            // username. nil reads as false.
            .field("trust_username", .bool)
            // The audience of the token-request JWT, for a platform whose
            // audience is not its token URL (Brightspace). nil = the token URL.
            .field("token_audience", .string)
            .unique(on: "issuer", "client_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APILTIPlatform.schema).delete()
    }
}
