// APIServer/Services/BrightSpaceCredentialStore.swift
//
// Persistence + resolution for captured BrightSpace Valence user keys.
//
// Two identity scopes share the `brightspace_credentials` table:
//   • the deployment-wide identity (`user_id IS NULL`) — the admin authorize /
//     env-supplied service account, kept as a fallback;
//   • one per-instructor identity (`user_id = <instructor>`) — captured via the
//     instructor "Connect my LEARN account" flow, used when a course designates
//     that instructor as its grade-sync identity.
//
// `resolveSyncConfig` decides the *global* identity (stored-global > env); the
// per-course choice (designated instructor > global) lives in
// `BrightSpaceClientRegistry` / `Application.brightSpaceClient(forCourse:)`.

import Fluent
import Vapor

enum BrightSpaceCredentialStore {

    /// The deployment-wide (admin/env) credential — the row with no `user_id`.
    static func loadGlobal(on db: any Database) async throws -> APIBrightSpaceCredential? {
        try await APIBrightSpaceCredential.query(on: db)
            .filter(\.$userID == nil)
            .sort(\.$capturedAt, .descending)
            .first()
    }

    /// The stored credential for one instructor, or nil if they haven't connected.
    static func load(userID: UUID, on db: any Database) async throws -> APIBrightSpaceCredential? {
        try await APIBrightSpaceCredential.query(on: db)
            .filter(\.$userID == userID)
            .sort(\.$capturedAt, .descending)
            .first()
    }

    /// Replaces the credential for one scope with a freshly captured one. A nil
    /// `userID` targets the deployment-wide identity; a non-nil one targets that
    /// instructor — so connecting a per-instructor key never disturbs the global
    /// fallback (or another instructor's key), and vice versa.
    static func save(
        valenceUserID: String,
        valenceUserKey: String,
        identityName: String?,
        capturedByUserID: UUID?,
        userID: UUID? = nil,
        on db: any Database
    ) async throws {
        if let userID {
            try await APIBrightSpaceCredential.query(on: db).filter(\.$userID == userID).delete()
        } else {
            try await APIBrightSpaceCredential.query(on: db).filter(\.$userID == nil).delete()
        }
        let record = APIBrightSpaceCredential(
            valenceUserID: valenceUserID,
            valenceUserKey: valenceUserKey,
            identityName: identityName,
            capturedByUserID: capturedByUserID,
            userID: userID
        )
        try await record.save(on: db)
    }

    /// Removes the deployment-wide credential (admin "Clear authorization").
    static func clearGlobal(on db: any Database) async throws {
        try await APIBrightSpaceCredential.query(on: db).filter(\.$userID == nil).delete()
    }

    /// Removes one instructor's credential (the instructor "Disconnect" action).
    static func clear(userID: UUID, on db: any Database) async throws {
        try await APIBrightSpaceCredential.query(on: db).filter(\.$userID == userID).delete()
    }

    /// Resolves the deployment-wide sync config from app creds: a stored global
    /// (authorized) user key wins; otherwise the env-provided full config; else
    /// nil (configured at the app level but awaiting a user key). This is the
    /// fallback used when a course has no designated per-instructor identity.
    static func resolveSyncConfig(
        app: BrightSpaceAppCredentials,
        envConfig: BrightSpaceSyncConfig?,
        on db: any Database
    ) async throws -> BrightSpaceSyncConfig? {
        if let stored = try await loadGlobal(on: db) {
            return BrightSpaceSyncConfig(
                app: app, userID: stored.valenceUserID, userKey: stored.valenceUserKey)
        }
        return envConfig
    }
}
