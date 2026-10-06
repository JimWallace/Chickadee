// APIServer/LTI/LTIPlatformKeyCache.swift
//
// Verifies a launch `id_token` against the platform's own key set
// (docs/lti-1-3.md "Launch"). Key sets are cached per platform, and fetched
// again once when a token does not verify: a platform rotates its key by
// publishing a new `kid`, and a stale cache must not refuse the first launch
// after that. A second failure is final.
//
// One fetch per platform at a time: concurrent launches that miss the cache
// join the fetch already in flight, so a class that opens a link together
// costs the platform one request, not one per student.

import Foundation
import JWT
import Vapor

actor LTIPlatformKeyCache {
    /// Fetches a key set document (JWKS JSON) from a URL.
    typealias Fetch = @Sendable (String) async throws -> String

    /// How long a key set is trusted before it is fetched again anyway.
    static let lifetime: TimeInterval = 3600
    /// The shortest gap between two forced fetches for one platform, so a
    /// stream of bad tokens cannot make Chickadee hammer the platform.
    static let refetchFloor: TimeInterval = 30

    private struct Entry {
        let jwksURL: String
        let keys: JWTKeyCollection
        let fetchedAt: Date
    }

    private struct LoadKey: Hashable {
        let platformID: UUID
        let jwksURL: String
    }

    private let fetch: Fetch
    private var entries: [UUID: Entry] = [:]
    private var loads: [LoadKey: Task<Entry, any Error>] = [:]

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Verifies `token` as launch claims signed by the platform `platformID`,
    /// whose key set lives at `jwksURL`.
    func verify(
        _ token: String, platformID: UUID, jwksURL: String, now: Date = Date()
    ) async throws
        -> LTILaunchClaims
    {
        let entry = try await entry(platformID: platformID, jwksURL: jwksURL, now: now)
        do {
            return try await entry.keys.verify(token, as: LTILaunchClaims.self)
        } catch {
            // Another launch may have fetched again while this one verified.
            if let current = entries[platformID], current.jwksURL == jwksURL, current.keys !== entry.keys {
                return try await current.keys.verify(token, as: LTILaunchClaims.self)
            }
            guard now.timeIntervalSince(entry.fetchedAt) >= Self.refetchFloor else { throw error }
            let fresh = try await load(platformID: platformID, jwksURL: jwksURL, now: now)
            return try await fresh.keys.verify(token, as: LTILaunchClaims.self)
        }
    }

    private func entry(platformID: UUID, jwksURL: String, now: Date) async throws -> Entry {
        if let cached = entries[platformID], cached.jwksURL == jwksURL,
            now.timeIntervalSince(cached.fetchedAt) < Self.lifetime
        {
            return cached
        }
        return try await load(platformID: platformID, jwksURL: jwksURL, now: now)
    }

    private func load(platformID: UUID, jwksURL: String, now: Date) async throws -> Entry {
        let key = LoadKey(platformID: platformID, jwksURL: jwksURL)
        if let running = loads[key] {
            return try await running.value
        }
        let fetch = self.fetch
        let task = Task {
            let json = try await fetch(jwksURL)
            let keys = try await JWTKeyCollection().add(jwksJSON: json)
            return Entry(jwksURL: jwksURL, keys: keys, fetchedAt: now)
        }
        loads[key] = task
        defer { loads[key] = nil }
        let entry = try await task.value
        entries[platformID] = entry
        return entry
    }
}

private struct LTIPlatformKeyCacheKey: StorageKey {
    typealias Value = LTIPlatformKeyCache
}

extension Application {
    /// The platform key cache. Created before the first request (see
    /// routes.swift); tests replace it with one whose fetch serves a test key.
    var ltiPlatformKeyCache: LTIPlatformKeyCache {
        get {
            lazyStored(LTIPlatformKeyCacheKey.self) {
                let client = self.client
                return LTIPlatformKeyCache { url in
                    let response = try await client.get(URI(string: url))
                    guard response.status == .ok else {
                        throw LTIServiceError.rejected(.keySet, status: response.status.code)
                    }
                    guard var body = response.body else { throw LTIServiceError.unreadableResponse(.keySet) }
                    return body.readString(length: body.readableBytes) ?? ""
                }
            }
        }
        set { storage[LTIPlatformKeyCacheKey.self] = newValue }
    }
}
