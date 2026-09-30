// Tests/APITests/LTI/LTIRoutesTests.swift
//
// `GET /lti/jwks` and the `lti_platforms` table (docs/lti-1-3.md slice 1).
// The compatibility rule under test: with no enabled platform, LTI changes
// nothing — the key set is empty and no key file is written.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTIRoutesTests {
    let app: Application
    let keyDirectory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti")
        keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        app.ltiToolKeyFilePath = keyDirectory.appendingPathComponent(".lti-tool-key").path
    }

    deinit {
        try? FileManager.default.removeItem(at: keyDirectory)
    }

    struct KeySet: Decodable {
        let keys: [[String: String]]
    }

    @discardableResult
    private func makePlatform(
        on app: Application, issuer: String = "https://lms.example.edu", enabled: Bool = true
    ) async throws -> APILTIPlatform {
        let platform = APILTIPlatform(
            issuer: issuer,
            clientID: "chickadee-client",
            deploymentIDs: ["deployment-1", " deployment-2 ", ""],
            authLoginURL: "https://lms.example.edu/d2l/lti/authenticate",
            accessTokenURL: "https://auth.example.edu/core/connect/token",
            jwksURL: "https://lms.example.edu/d2l/.well-known/jwks",
            displayName: "Example LMS",
            enabled: enabled)
        try await platform.save(on: app.db)
        return platform
    }

    private func fetchKeySet(on app: Application) async throws -> KeySet {
        var keySet: KeySet?
        try await app.asyncTest(.GET, "/lti/jwks") { res in
            #expect(res.status == .ok)
            #expect(res.headers.contentType == .json)
            keySet = try res.content.decode(KeySet.self)
        }
        return try #require(keySet)
    }

    @Test func keySetIsEmptyAndNoKeyIsWrittenWithoutAPlatform() async throws {
        try await withApp(app) { app in
            let keySet = try await fetchKeySet(on: app)
            #expect(keySet.keys.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: app.ltiToolKeyFilePath))
        }
    }

    @Test func keySetIsEmptyWhenEveryPlatformIsDisabled() async throws {
        try await withApp(app) { app in
            try await makePlatform(on: app, enabled: false)
            let keySet = try await fetchKeySet(on: app)
            #expect(keySet.keys.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: app.ltiToolKeyFilePath))
        }
    }

    @Test func keySetPublishesOneStableRS256KeyOnceAPlatformIsEnabled() async throws {
        try await withApp(app) { app in
            try await makePlatform(on: app)
            let first = try await fetchKeySet(on: app)
            let key = try #require(first.keys.first)
            #expect(first.keys.count == 1)
            #expect(key["kty"] == "RSA")
            #expect(key["alg"] == "RS256")
            #expect(key["d"] == nil)
            #expect(FileManager.default.fileExists(atPath: app.ltiToolKeyFilePath))

            let second = try await fetchKeySet(on: app)
            #expect(second.keys.first?["kid"] == key["kid"])
        }
    }

    /// Brightspace could not read a deflate-encoded key set and reported the
    /// URL as unreachable. Compression runs in the server pipeline, so this
    /// needs a running server, not an in-memory test.
    @Test func keySetIsSentUncompressedEvenWhenTheClientAcceptsCompression() async throws {
        try await withApp(app) { app in
            app.http.server.configuration.responseCompression = .enabledForCompressibleTypes
            try await makePlatform(on: app)
            try await app.testing(method: .running(hostname: "localhost", port: 0)).test(
                .GET, "/lti/jwks",
                headers: ["Accept-Encoding": "gzip, deflate"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == nil)
                let keySet = try? res.content.decode(KeySet.self)
                #expect(keySet?.keys.count == 1)
            }
        }
    }

    @Test func keySetNeedsNoSession() async throws {
        try await withApp(app) { app in
            try await makePlatform(on: app)
            try await app.asyncTest(.GET, "/lti/jwks") { res in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .location) == nil)
            }
        }
    }

    @Test func deploymentIDsRoundTripTrimmedWithBlanksDropped() async throws {
        try await withApp(app) { app in
            let saved = try await makePlatform(on: app)
            let loaded = try #require(try await APILTIPlatform.find(saved.id, on: app.db))
            #expect(loaded.deploymentIDs == ["deployment-1", "deployment-2"])
            #expect(loaded.registration.deploymentIDs == ["deployment-1", "deployment-2"])
            #expect(loaded.registration.issuer == "https://lms.example.edu")
            #expect(loaded.registration.clientID == "chickadee-client")
        }
    }

    @Test func issuerAndClientIDPairIsUnique() async throws {
        try await withApp(app) { app in
            try await makePlatform(on: app)
            await #expect(throws: (any Error).self) {
                try await self.makePlatform(on: app)
            }
            // The same client ID under another issuer is a different registration.
            try await makePlatform(on: app, issuer: "https://other-lms.example.edu")
            let count = try await APILTIPlatform.query(on: app.db).count()
            #expect(count == 2)
        }
    }
}
