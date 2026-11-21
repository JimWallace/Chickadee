// Tests/APITests/BrightSpace/BrightSpaceConnectionServiceConnectTests.swift
//
// `BrightSpaceConnectionService.connect` against a scripted D2L: a pair that
// whoami accepts is stored under the instructor and claims an active course
// that has no sync identity yet; a pair that whoami refuses stores nothing.
// `BrightSpaceConnectionServiceTests` covers the paths that need no D2L.

import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class BrightSpaceConnectionServiceConnectTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-bs-connect")
    }

    private static let appCredentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.test", appID: "app-id", appKey: "app-key", debounceSecs: 90)

    /// Answers whoami with `whoami` (or `status` when it is not OK) and every
    /// other request with 404, so version discovery falls back.
    private func scriptD2L(status: HTTPResponseStatus = .ok, whoami: String) {
        app.brightSpaceAppCredentials = Self.appCredentials
        _ = app.useScriptedValence { _, url, _ in
            guard url.contains("/users/whoami") else { return ScriptedValenceReply(.notFound) }
            return status == .ok ? ScriptedValenceReply(.ok, whoami) : ScriptedValenceReply(status, "{}")
        }
    }

    private static let fullIdentity =
        #"{"Identifier":"42","FirstName":"Pat","LastName":"Lee","UniqueName":"plee"}"#

    @Test func anAcceptedPairIsStoredAndClaimsAnUndesignatedCourse() async throws {
        try await withApp(app) { app in
            scriptD2L(whoami: Self.fullIdentity)
            let course = try await makeTestCourse(on: app, code: "BCC1")
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let userUUID = try instructor.requireID()

            let connection = try await BrightSpaceConnectionService.connect(
                userUUID: userUUID, valenceUserID: "v-user", valenceUserKey: "v-key",
                activeCourseUUID: try course.requireID(), on: app.db, application: app)

            #expect(connection == .init(identity: "Pat Lee (plee)", claimedCourse: true))
            let stored = try #require(try await BrightSpaceCredentialStore.load(userID: userUUID, on: app.db))
            #expect(stored.valenceUserID == "v-user")
            #expect(stored.identityName == "Pat Lee (plee)")
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceSyncUserID == userUUID)
        }
    }

    @Test func aCourseWithASyncIdentityKeepsIt() async throws {
        try await withApp(app) { app in
            scriptD2L(whoami: Self.fullIdentity)
            let course = try await makeTestCourse(on: app, code: "BCC2")
            let incumbent = UUID()
            course.brightspaceSyncUserID = incumbent
            try await course.save(on: app.db)
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let userUUID = try instructor.requireID()

            let connection = try await BrightSpaceConnectionService.connect(
                userUUID: userUUID, valenceUserID: "v-user", valenceUserKey: "v-key",
                activeCourseUUID: try course.requireID(), on: app.db, application: app)

            #expect(connection.claimedCourse == false)
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceSyncUserID == incumbent)
            #expect(try await BrightSpaceCredentialStore.load(userID: userUUID, on: app.db) != nil)
        }
    }

    @Test func withoutAnActiveCourseNothingIsClaimed() async throws {
        try await withApp(app) { app in
            // No UniqueName: the identity is the display name alone.
            scriptD2L(whoami: #"{"Identifier":"7","FirstName":"Pat","LastName":"Lee"}"#)
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")

            let connection = try await BrightSpaceConnectionService.connect(
                userUUID: try instructor.requireID(), valenceUserID: "v-user", valenceUserKey: "v-key",
                activeCourseUUID: nil, on: app.db, application: app)

            #expect(connection == .init(identity: "Pat Lee", claimedCourse: false))
        }
    }

    @Test func aRefusedPairStoresNothingAndClaimsNothing() async throws {
        try await withApp(app) { app in
            scriptD2L(status: .unauthorized, whoami: "")
            let course = try await makeTestCourse(on: app, code: "BCC3")
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let userUUID = try instructor.requireID()

            await #expect {
                _ = try await BrightSpaceConnectionService.connect(
                    userUUID: userUUID, valenceUserID: "v-user", valenceUserKey: "bad-key",
                    activeCourseUUID: try course.requireID(), on: app.db, application: app)
            } throws: { error in
                guard case .credentialsRejected = error as? BrightSpaceConnectionService.ConnectError else {
                    return false
                }
                return true
            }

            #expect(try await BrightSpaceCredentialStore.load(userID: userUUID, on: app.db) == nil)
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceSyncUserID == nil)
        }
    }
}
