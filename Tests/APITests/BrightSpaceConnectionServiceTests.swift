// Tests/APITests/BrightSpaceConnectionServiceTests.swift
//
// The per-instructor LEARN connection without a request: designating a
// course's sync identity needs a stored key, disconnecting drops it, and a
// server with no BrightSpace app credentials refuses to connect. The whoami
// verification itself needs D2L, so it is covered only by the signing and
// transport tests.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class BrightSpaceConnectionServiceTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp()
    }

    @Test func designatingNeedsAStoredKey() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "BC1")
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let userUUID = try instructor.requireID()

            await #expect(throws: BrightSpaceConnectionService.DesignateError.notConnected) {
                try await BrightSpaceConnectionService.designate(userUUID: userUUID, course: course, on: app.db)
            }
            #expect(course.brightspaceSyncUserID == nil)

            try await BrightSpaceCredentialStore.save(
                valenceUserID: "u", valenceUserKey: "k", identityName: "Prof Lee",
                capturedByUserID: userUUID, userID: userUUID, on: app.db)
            try await BrightSpaceConnectionService.designate(userUUID: userUUID, course: course, on: app.db)
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceSyncUserID == userUUID)
        }
    }

    @Test func disconnectingDropsTheStoredKey() async throws {
        try await withApp(app) { app in
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let userUUID = try instructor.requireID()
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "u", valenceUserKey: "k", identityName: "Prof Lee",
                capturedByUserID: userUUID, userID: userUUID, on: app.db)

            try await BrightSpaceConnectionService.disconnect(
                userUUID: userUUID, on: app.db, application: app)

            #expect(try await BrightSpaceCredentialStore.load(userID: userUUID, on: app.db) == nil)
        }
    }

    @Test func connectingNeedsTheServerConfigured() async throws {
        try await withApp(app) { app in
            app.brightSpaceAppCredentials = nil
            await #expect(throws: BrightSpaceConnectionService.ConnectError.notConfigured) {
                _ = try await BrightSpaceConnectionService.connect(
                    userUUID: UUID(), valenceUserID: "u", valenceUserKey: "k",
                    activeCourseUUID: nil, on: app.db, application: app)
            }
        }
    }
}
