// APIServer/Services/BrightSpaceClientRegistry.swift
//
// Per-identity cache of BrightSpace API clients, and the per-course identity
// resolution that decides *whose* LEARN key a grade push runs as.
//
// Grade sync moved from one deployment-wide service account to a per-instructor
// model: each course designates an instructor (`brightspace_sync_user_id`) whose
// connected Valence key drives its pushes; a course with no designation falls
// back to the deployment-wide (admin/env) identity. A `BrightSpaceAPIClient`
// caches negotiated API versions + learned clock skew, so we keep one client per
// identity rather than rebuilding it every sweep.

import Fluent
import Vapor

/// Caches one `BrightSpaceAPIClient` per identity key so repeated pushes reuse a
/// client's negotiated API version + clock-skew state instead of re-negotiating.
actor BrightSpaceClientRegistry {
    /// Cache key for the deployment-wide (admin/env) identity.
    static let globalKey = "__global__"

    private var clients: [String: BrightSpaceAPIClient] = [:]

    /// The client for `key`, built from `config` on first use and cached.
    func client(forKey key: String, config: BrightSpaceSyncConfig) -> BrightSpaceAPIClient {
        if let existing = clients[key] { return existing }
        let created = BrightSpaceAPIClient(config: config)
        clients[key] = created
        return created
    }

    /// Drops a cached client so the next resolve rebuilds it (after a key is
    /// (re)connected, cleared, or the global config changes).
    func invalidate(_ key: String) {
        clients.removeValue(forKey: key)
    }

    func invalidateAll() {
        clients.removeAll()
    }
}

/// The effective grade-sync config + cache key for a course: its designated
/// instructor's stored key if set, else the deployment-wide config. Returns nil
/// when neither is available (BrightSpace not connected for this course).
func resolveBrightSpaceConfigForCourse(
    _ course: APICourse,
    app: BrightSpaceAppCredentials,
    globalConfig: BrightSpaceSyncConfig?,
    on db: any Database
) async throws -> (config: BrightSpaceSyncConfig, key: String)? {
    if let syncUserID = course.brightspaceSyncUserID,
        let credential = try await BrightSpaceCredentialStore.load(userID: syncUserID, on: db)
    {
        let config = BrightSpaceSyncConfig(
            app: app, userID: credential.valenceUserID, userKey: credential.valenceUserKey)
        return (config, syncUserID.uuidString)
    }
    if let globalConfig {
        return (globalConfig, BrightSpaceClientRegistry.globalKey)
    }
    return nil
}

// MARK: - Application storage

struct BrightSpaceClientRegistryKey: StorageKey {
    typealias Value = BrightSpaceClientRegistry
}

extension Application {
    var brightSpaceClientRegistry: BrightSpaceClientRegistry {
        get {
            if let existing = storage[BrightSpaceClientRegistryKey.self] { return existing }
            let created = BrightSpaceClientRegistry()
            storage[BrightSpaceClientRegistryKey.self] = created
            return created
        }
        set { storage[BrightSpaceClientRegistryKey.self] = newValue }
    }

    /// Resolves the grade-sync client for a course's designated identity (or the
    /// deployment-wide fallback), cached per identity. Nil when BrightSpace isn't
    /// configured at the app level, or no identity is available for the course.
    func brightSpaceClient(forCourse course: APICourse) async throws -> BrightSpaceAPIClient? {
        guard let app = brightSpaceAppCredentials else { return nil }
        guard
            let resolved = try await resolveBrightSpaceConfigForCourse(
                course, app: app, globalConfig: brightSpaceSyncConfig, on: db)
        else { return nil }
        return await brightSpaceClientRegistry.client(forKey: resolved.key, config: resolved.config)
    }
}
