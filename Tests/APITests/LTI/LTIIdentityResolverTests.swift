// Tests/APITests/LTI/LTIIdentityResolverTests.swift
//
// Who a launch signs in as (docs/lti-1-3.md "Identity"). The refusals are
// the security boundary: a launch must never claim an admin or MCP account,
// and never attach a second subject from one platform to one account.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTIIdentityResolverTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-identity")
    }

    private func makePlatform(trustUsername: Bool) async throws -> APILTIPlatform {
        let platform = APILTIPlatform(
            issuer: "https://lms.example.edu", clientID: "client", deploymentIDs: ["d"],
            authLoginURL: "https://lms.example.edu/auth", accessTokenURL: "https://lms.example.edu/token",
            jwksURL: "https://lms.example.edu/jwks", displayName: "LMS")
        platform.trustUsername = trustUsername
        try await platform.save(on: app.db)
        return platform
    }

    private func launch(subject: String = "subject-1", username: String? = nil) throws -> LTIValidatedLaunch {
        let claims = LTITestPlatform.claims(
            nonce: "n", subject: subject, custom: username.map { ["username": .string($0)] } ?? [:])
        let registration = LTIPlatformRegistration(
            issuer: LTITestPlatform.issuer, clientID: LTITestPlatform.clientID,
            deploymentIDs: [LTITestPlatform.deploymentID])
        return try LTILaunchValidator.validate(claims, against: registration, now: Date())
    }

    private func resolve(
        _ launch: LTIValidatedLaunch, _ platform: APILTIPlatform, authMode: AuthMode = .local
    ) async throws -> LTIIdentityResolver.Resolution {
        try await LTIIdentityResolver.resolve(launch: launch, platform: platform, authMode: authMode, on: app.db)
    }

    @Test func untrustedPlatformGivesEachSubjectAnOpaqueAccount() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: false)
            try await makeTestUser(on: app, username: "alovelace", role: "user")
            let first = try await resolve(try launch(username: "alovelace"), platform)
            #expect(first.created)
            #expect(first.user.username.hasPrefix("lti-"))
            #expect(first.user.username != "alovelace")
            let again = try await resolve(try launch(username: "alovelace"), platform)
            #expect(!again.created)
            #expect(again.user.id == first.user.id)
        }
    }

    @Test func trustedPlatformLinksToTheExistingAccount() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: true)
            let existing = try await makeTestUser(on: app, username: "alovelace", role: "user")
            let resolution = try await resolve(try launch(username: " ALovelace "), platform)
            #expect(!resolution.created)
            #expect(resolution.user.id == existing.id)
        }
    }

    @Test(arguments: [(AuthMode.sso, "duo-oidc"), (AuthMode.local, "lti")])
    func trustedPlatformCreatesAnAccountDUOCanAdopt(mode: AuthMode, provider: String) async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: true)
            let resolution = try await resolve(try launch(username: "bbabbage"), platform, authMode: mode)
            #expect(resolution.created)
            #expect(resolution.user.username == "bbabbage")
            #expect(resolution.user.authProvider == provider)
            #expect(resolution.user.externalSubject == nil)
        }
    }

    @Test(arguments: ["admin", "mcp"])
    func trustedPlatformNeverClaimsAPrivilegedAccount(role: String) async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: true)
            try await makeTestUser(on: app, username: "root", role: role)
            await #expect(throws: LTIIdentityResolver.Failure.linkRefused(username: "root")) {
                try await self.resolve(try self.launch(username: "root"), platform)
            }
        }
    }

    @Test func trustedPlatformNeverGivesOneAccountTwoSubjects() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: true)
            try await makeTestUser(on: app, username: "alovelace", role: "user")
            _ = try await resolve(try launch(subject: "subject-1", username: "alovelace"), platform)
            await #expect(throws: LTIIdentityResolver.Failure.linkRefused(username: "alovelace")) {
                try await self.resolve(try self.launch(subject: "subject-2", username: "alovelace"), platform)
            }
        }
    }

    @Test(arguments: ["", "  ", "$User.username"])
    func unsubstitutedOrBlankUsernameFallsBackToAnOpaqueAccount(username: String) async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: true)
            let resolution = try await resolve(try launch(username: username), platform)
            #expect(resolution.user.username.hasPrefix("lti-"))
        }
    }

    @Test func twoConcurrentFirstLaunchesOfOneSubjectShareOneAccount() async throws {
        try await withApp(app) { app in
            let platform = try await makePlatform(trustUsername: false)
            let validated = try launch(subject: "raced-subject")
            let db = app.db
            async let first = LTIIdentityResolver.resolve(
                launch: validated, platform: platform, authMode: .local, on: db)
            async let second = LTIIdentityResolver.resolve(
                launch: validated, platform: platform, authMode: .local, on: db)
            let (a, b) = try await (first, second)
            #expect(a.user.id == b.user.id)
            let links = try await APILTIIdentity.query(on: app.db).filter(\.$subject == "raced-subject").count()
            #expect(links == 1)
        }
    }
}

/// Pure: no app. A class suite whose test never enters `withApp` leaks an
/// application that was never shut down, which Vapor traps on.
@Suite struct LTIOpaqueUsernameTests {
    @Test func opaqueUsernameIsStableAndDiffersPerSubject() {
        let platformID = UUID()
        let a = LTIIdentityResolver.opaqueUsername(platformID: platformID, subject: "a")
        #expect(a == LTIIdentityResolver.opaqueUsername(platformID: platformID, subject: "a"))
        #expect(a != LTIIdentityResolver.opaqueUsername(platformID: platformID, subject: "b"))
        #expect(a != LTIIdentityResolver.opaqueUsername(platformID: UUID(), subject: "a"))
        #expect(a.count == "lti-".count + 16)
    }
}
