// Tests/APITests/BrightSpaceCredentialStoreTests.swift
//
// Round-trip + precedence tests for the authorize-captured BrightSpace user-key
// store: a single active row, and "an authorized (stored) key wins over an
// env-provided user key, with env as the fallback".

import Fluent
import Foundation
import Testing
import VaporTesting

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

            let loaded = try #require(try await BrightSpaceCredentialStore.loadGlobal(on: app.db))
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
            try await BrightSpaceCredentialStore.clearGlobal(on: app.db)
            let r3 = try await BrightSpaceCredentialStore.resolveSyncConfig(
                app: creds, envConfig: nil, on: app.db)
            #expect(r3 == nil)
        }
    }

    @Test func perUserCredentials_areScopedAndIsolated() async throws {
        try await withApp(app) { app in
            let userA = UUID()
            let userB = UUID()
            // A deployment-wide identity and two per-instructor identities coexist.
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "g", valenceUserKey: "gk", identityName: "Global",
                capturedByUserID: nil, userID: nil, on: app.db)
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "a", valenceUserKey: "ak", identityName: "Alice",
                capturedByUserID: userA, userID: userA, on: app.db)
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "b", valenceUserKey: "bk", identityName: "Bob",
                capturedByUserID: userB, userID: userB, on: app.db)

            #expect(try await APIBrightSpaceCredential.query(on: app.db).count() == 3)
            let global = try #require(try await BrightSpaceCredentialStore.loadGlobal(on: app.db))
            #expect(global.valenceUserID == "g")
            #expect(global.userID == nil)
            #expect(try await BrightSpaceCredentialStore.load(userID: userA, on: app.db)?.valenceUserID == "a")
            #expect(try await BrightSpaceCredentialStore.load(userID: userB, on: app.db)?.valenceUserID == "b")

            // Re-connecting one instructor replaces only their row.
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "a2", valenceUserKey: "ak2", identityName: "Alice2",
                capturedByUserID: userA, userID: userA, on: app.db)
            #expect(try await APIBrightSpaceCredential.query(on: app.db).count() == 3)
            #expect(try await BrightSpaceCredentialStore.load(userID: userA, on: app.db)?.valenceUserID == "a2")
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db)?.valenceUserID == "g")
            #expect(try await BrightSpaceCredentialStore.load(userID: userB, on: app.db)?.valenceUserID == "b")

            // Disconnecting one instructor leaves the others + the global identity.
            try await BrightSpaceCredentialStore.clear(userID: userA, on: app.db)
            #expect(try await BrightSpaceCredentialStore.load(userID: userA, on: app.db) == nil)
            #expect(try await BrightSpaceCredentialStore.loadGlobal(on: app.db) != nil)
            #expect(try await BrightSpaceCredentialStore.load(userID: userB, on: app.db) != nil)
        }
    }

    @Test func resolveConfigForCourse_designatedWinsThenGlobalThenNil() async throws {
        try await withApp(app) { app in
            let appCreds = BrightSpaceAppCredentials(
                baseURL: "https://x", appID: "a", appKey: "ak", debounceSecs: 90)
            let globalConfig = BrightSpaceSyncConfig(
                app: appCreds, userID: "envUser", userKey: "envKey")

            let instructor = UUID()
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "insUser", valenceUserKey: "insKey", identityName: "Ins",
                capturedByUserID: instructor, userID: instructor, on: app.db)

            let course = try await makeTestCourse(on: app, code: "BSRES")

            // No designation → deployment-wide fallback.
            let r1 = try await resolveBrightSpaceConfigForCourse(
                course, app: appCreds, globalConfig: globalConfig, on: app.db)
            #expect(r1?.config.userID == "envUser")
            #expect(r1?.key == BrightSpaceClientRegistry.globalKey)

            // Designated instructor with a stored key → their identity wins.
            course.brightspaceSyncUserID = instructor
            try await course.save(on: app.db)
            let r2 = try await resolveBrightSpaceConfigForCourse(
                course, app: appCreds, globalConfig: globalConfig, on: app.db)
            #expect(r2?.config.userID == "insUser")
            #expect(r2?.config.userKey == "insKey")
            #expect(r2?.key == instructor.uuidString)

            // Designated but disconnected (no stored key) → falls back to global.
            course.brightspaceSyncUserID = UUID()
            try await course.save(on: app.db)
            let r3 = try await resolveBrightSpaceConfigForCourse(
                course, app: appCreds, globalConfig: globalConfig, on: app.db)
            #expect(r3?.config.userID == "envUser")
            #expect(r3?.key == BrightSpaceClientRegistry.globalKey)

            // No global fallback + no usable designation → nil (sync deferred).
            let r4 = try await resolveBrightSpaceConfigForCourse(
                course, app: appCreds, globalConfig: nil, on: app.db)
            #expect(r4 == nil)
        }
    }
}
