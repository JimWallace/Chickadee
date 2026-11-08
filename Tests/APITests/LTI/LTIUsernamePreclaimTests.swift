// Tests/APITests/LTI/LTIUsernamePreclaimTests.swift
//
// On a platform trusted for usernames, a launch linked to ANY existing
// non-admin account with that username, including one a stranger registered
// with a local password (#2899). The stranger then held the LMS user's role.
// A launch now links only to an account with no local password; otherwise it
// gets its own opaque account.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
struct LTIUsernamePreclaimTests {

    private func makePlatform(on app: Application) async throws -> APILTIPlatform {
        let platform = APILTIPlatform(
            issuer: "https://lms.example.edu", clientID: "client", deploymentIDs: ["d"],
            authLoginURL: "https://lms.example.edu/auth", accessTokenURL: "https://lms.example.edu/token",
            jwksURL: "https://lms.example.edu/jwks", displayName: "LMS")
        platform.trustUsername = true
        try await platform.save(on: app.db)
        return platform
    }

    private func launch(username: String) throws -> LTIValidatedLaunch {
        let claims = LTITestPlatform.claims(
            nonce: "n", subject: "alice-subject", custom: ["username": .string(username)])
        let registration = LTIPlatformRegistration(
            issuer: LTITestPlatform.issuer, clientID: LTITestPlatform.clientID,
            deploymentIDs: [LTITestPlatform.deploymentID])
        return try LTILaunchValidator.validate(claims, against: registration, now: Date())
    }

    @Test func aLocallyRegisteredAccountIsNotClaimed() async throws {
        try await withTestApp(prefix: "chickadee-lti-preclaim") { app in
            let platform = try await makePlatform(on: app)
            // The stranger's account: registered with a password they know.
            let squatter = try await makeTestUser(on: app, username: "alice", role: "user")
            let resolution = try await LTIIdentityResolver.resolve(
                launch: try launch(username: "alice"), platform: platform, authMode: .dual, on: app.db)
            #expect(resolution.user.id != squatter.id)
            #expect(resolution.user.username.hasPrefix("lti-"))
            #expect(resolution.created)
        }
    }
}
