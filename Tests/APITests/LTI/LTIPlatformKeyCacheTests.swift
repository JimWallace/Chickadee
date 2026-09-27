// Tests/APITests/LTI/LTIPlatformKeyCacheTests.swift
//
// The platform key cache: fetch once, reuse, fetch again once when a platform
// rotates its key, and never refetch faster than the floor.

import Foundation
import Synchronization
import Testing

@testable import APIServer

@Suite struct LTIPlatformKeyCacheTests {
    /// Counts fetches and serves whichever key set is current.
    final class FakeKeyServer: Sendable {
        let fetches = Mutex(0)
        let current: Mutex<String>

        init(_ json: String) { current = Mutex(json) }

        var fetch: LTIPlatformKeyCache.Fetch {
            { _ in
                self.fetches.withLock { $0 += 1 }
                return self.current.withLock { $0 }
            }
        }
    }

    @Test func keySetIsFetchedOnceAndReused() async throws {
        let platform = try await LTITestPlatform.make()
        defer { platform.cleanUp() }
        let server = FakeKeyServer(try await platform.jwksJSON())
        let cache = LTIPlatformKeyCache(fetch: server.fetch)
        let id = UUID()
        for nonce in ["a", "b"] {
            let token = try await platform.sign(LTITestPlatform.claims(nonce: nonce))
            let claims = try await cache.verify(token, platformID: id, jwksURL: "https://lms/jwks")
            #expect(claims.nonce == nonce)
        }
        #expect(server.fetches.withLock { $0 } == 1)
    }

    @Test func rotatedKeyIsPickedUpByOneRefetch() async throws {
        let old = try await LTITestPlatform.make()
        let new = try await LTITestPlatform.make()
        defer {
            old.cleanUp()
            new.cleanUp()
        }
        let server = FakeKeyServer(try await old.jwksJSON())
        let cache = LTIPlatformKeyCache(fetch: server.fetch)
        let id = UUID()
        let start = Date()
        _ = try await cache.verify(
            try await old.sign(LTITestPlatform.claims(nonce: "a")), platformID: id, jwksURL: "u", now: start)

        let rotated = try await new.jwksJSON()
        server.current.withLock { $0 = rotated }
        let later = start.addingTimeInterval(LTIPlatformKeyCache.refetchFloor + 1)
        let claims = try await cache.verify(
            try await new.sign(LTITestPlatform.claims(nonce: "b")), platformID: id, jwksURL: "u", now: later)
        #expect(claims.nonce == "b")
        #expect(server.fetches.withLock { $0 } == 2)
    }

    @Test func refetchWaitsForTheFloor() async throws {
        let platform = try await LTITestPlatform.make()
        let impostor = try await LTITestPlatform.make()
        defer {
            platform.cleanUp()
            impostor.cleanUp()
        }
        let server = FakeKeyServer(try await platform.jwksJSON())
        let cache = LTIPlatformKeyCache(fetch: server.fetch)
        let token = try await impostor.sign(LTITestPlatform.claims(nonce: "a"))
        await #expect(throws: (any Error).self) {
            _ = try await cache.verify(token, platformID: UUID(), jwksURL: "u")
        }
        #expect(server.fetches.withLock { $0 } == 1)
    }
}
