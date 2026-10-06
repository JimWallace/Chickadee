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

        let delay: Duration

        init(_ json: String, delay: Duration = .zero) {
            current = Mutex(json)
            self.delay = delay
        }

        var fetch: LTIPlatformKeyCache.Fetch {
            { _ in
                self.fetches.withLock { $0 += 1 }
                // A slow platform keeps the fetch in flight while other
                // launches arrive.
                if self.delay > .zero { try await Task.sleep(for: self.delay) }
                return self.current.withLock { $0 }
            }
        }
    }

    /// Verifies `tokens` at the same time and returns the nonces in order.
    private func verifyConcurrently(
        _ tokens: [String], cache: LTIPlatformKeyCache, platformID: UUID, now: Date
    ) async throws -> [String?] {
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for (index, token) in tokens.enumerated() {
                group.addTask {
                    let claims = try await cache.verify(token, platformID: platformID, jwksURL: "u", now: now)
                    return (index, claims.nonce)
                }
            }
            var nonces = [String?](repeating: nil, count: tokens.count)
            for try await (index, nonce) in group { nonces[index] = nonce }
            return nonces
        }
    }

    @Test func concurrentFirstLaunchesShareOneFetch() async throws {
        let platform = try await LTITestPlatform.make()
        defer { platform.cleanUp() }
        let server = FakeKeyServer(try await platform.jwksJSON(), delay: .milliseconds(500))
        let cache = LTIPlatformKeyCache(fetch: server.fetch)
        let nonces = (0..<8).map { "n\($0)" }
        var tokens: [String] = []
        for nonce in nonces {
            tokens.append(try await platform.sign(LTITestPlatform.claims(nonce: nonce)))
        }

        let verified = try await verifyConcurrently(tokens, cache: cache, platformID: UUID(), now: Date())
        #expect(verified == nonces)
        #expect(server.fetches.withLock { $0 } == 1)
    }

    @Test func concurrentLaunchesAfterARotationShareOneRefetch() async throws {
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
        let nonces = (0..<8).map { "r\($0)" }
        var tokens: [String] = []
        for nonce in nonces {
            tokens.append(try await new.sign(LTITestPlatform.claims(nonce: nonce)))
        }
        let later = start.addingTimeInterval(LTIPlatformKeyCache.refetchFloor + 1)

        let verified = try await verifyConcurrently(tokens, cache: cache, platformID: id, now: later)
        #expect(verified == nonces)
        #expect(server.fetches.withLock { $0 } == 2)
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
