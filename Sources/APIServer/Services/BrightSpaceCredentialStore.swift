// APIServer/Services/BrightSpaceCredentialStore.swift
//
// Persistence + resolution for the authorize-captured BrightSpace user key.
//
// `resolveSyncConfig` is the single place that decides the active grade-sync
// identity: an authorized (stored) key takes precedence over an env-supplied
// user key, with env remaining the bootstrap fallback. Used both at startup
// (AppServices) and after a fresh authorization (AdminRoutes+BrightSpace) so
// the running client reflects the latest deliberate action.

import Fluent
import Vapor

enum BrightSpaceCredentialStore {

    /// The most recently authorized credential, or nil if none stored.
    static func load(on db: any Database) async throws -> APIBrightSpaceCredential? {
        try await APIBrightSpaceCredential.query(on: db)
            .sort(\.$capturedAt, .descending)
            .first()
    }

    /// Replaces any stored credential with a freshly captured one (single-row).
    static func save(
        valenceUserID: String,
        valenceUserKey: String,
        identityName: String?,
        capturedByUserID: UUID?,
        on db: any Database
    ) async throws {
        try await APIBrightSpaceCredential.query(on: db).delete()
        let record = APIBrightSpaceCredential(
            valenceUserID: valenceUserID,
            valenceUserKey: valenceUserKey,
            identityName: identityName,
            capturedByUserID: capturedByUserID
        )
        try await record.save(on: db)
    }

    /// Removes the stored credential (the admin "Clear authorization" action).
    static func clear(on db: any Database) async throws {
        try await APIBrightSpaceCredential.query(on: db).delete()
    }

    /// Resolves the active sync config from deployment app creds: a stored
    /// (authorized) user key wins; otherwise the env-provided full config is
    /// used; otherwise nil (configured at the app level but awaiting a user key).
    static func resolveSyncConfig(
        app: BrightSpaceAppCredentials,
        envConfig: BrightSpaceSyncConfig?,
        on db: any Database
    ) async throws -> BrightSpaceSyncConfig? {
        if let stored = try await load(on: db) {
            return BrightSpaceSyncConfig(
                app: app, userID: stored.valenceUserID, userKey: stored.valenceUserKey)
        }
        return envConfig
    }
}
