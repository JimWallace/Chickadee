// Tests/APITests/BrightSpaceCredentialStoreTests.swift
//
// Round-trip + precedence tests for the authorize-captured BrightSpace user-key
// store: a single active row, and "an authorized (stored) key wins over an
// env-provided user key, with env as the fallback".

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite(.serialized) final class BrightSpaceCredentialStoreTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bs-cred")
    }

    @Test func save_keepsSingleMostRecentRow() async throws {
        try await withApp(app) { app in
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "u1", valenceUserKey: "k1", identityName: "Alice",
                capturedByUserID: nil, on: app.db)
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "u2", valenceUserKey: "k2", identityName: "Bob",
                capturedByUserID: nil, on: app.db)

            let count = try await APIBrightSpaceCredential.query(on: app.db).count()
            #expect(count == 1)

            let loaded = try #require(try await BrightSpaceCredentialStore.load(on: app.db))
            #expect(loaded.valenceUserID == "u2")
            #expect(loaded.valenceUserKey == "k2")
            #expect(loaded.identityName == "Bob")
        }
    }

    @Test func resolveSyncConfig_storedKeyWinsThenEnvThenNil() async throws {
        try await withApp(app) { app in
            let creds = BrightSpaceAppCredentials(
                baseURL: "https://x", appID: "a", appKey: "ak", debounceSecs: 90)
            let envConfig = BrightSpaceSyncConfig(
                baseURL: "https://x", appID: "a", appKey: "ak",
                userID: "envUser", userKey: "envKey", debounceSecs: 90)

            // No stored row → the env config is used.
            let r1 = try await BrightSpaceCredentialStore.resolveSyncConfig(
                app: creds, envConfig: envConfig, on: app.db)
            #expect(r1?.userID == "envUser")

            // Stored row → it takes precedence over env.
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "storedUser", valenceUserKey: "storedKey",
                identityName: nil, capturedByUserID: nil, on: app.db)
            let r2 = try await BrightSpaceCredentialStore.resolveSyncConfig(
                app: creds, envConfig: envConfig, on: app.db)
            #expect(r2?.userID == "storedUser")
            #expect(r2?.userKey == "storedKey")

            // Cleared + no env → nil (configured at app level, awaiting authorize).
            try await BrightSpaceCredentialStore.clear(on: app.db)
            let r3 = try await BrightSpaceCredentialStore.resolveSyncConfig(
                app: creds, envConfig: nil, on: app.db)
            #expect(r3 == nil)
        }
    }
}
