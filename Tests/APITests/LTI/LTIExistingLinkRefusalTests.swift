// Tests/APITests/LTI/LTIExistingLinkRefusalTests.swift
//
// A link made earlier never signs an LMS user in to an admin or MCP account
// (docs/compliance/lti-audit-2026-10.md L-2). An account can become one after
// it was linked: an admin promotes it, or an SSO admin's first DUO sign-in
// adopts a stub that a trusted launch created for that username.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTIExistingLinkRefusalTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-existing-link")
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

    private func launch(username: String? = nil) throws -> LTIValidatedLaunch {
        let claims = LTITestPlatform.claims(
            nonce: "n", custom: username.map { ["username": .string($0)] } ?? [:])
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

    @Test(arguments: [UserRole.admin, UserRole.mcp])
    func aLinkedAccountThatGainsAPrivilegedRoleIsRefused(role: UserRole) async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: false)
            let first = try await resolve(try launch(), platform)
            #expect(first.created)

            first.user.role = role.rawValue
            try await first.user.save(on: app.db)

            await #expect(throws: LTIIdentityResolver.Failure.linkRefused(username: first.user.username)) {
                _ = try await self.resolve(try self.launch(), platform)
            }
        }
    }

    @Test func aStubAdoptedByAnSSOAdminIsRefused() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: true)
            let stub = try await resolve(try launch(username: "root"), platform, authMode: .sso)
            #expect(stub.created)
            #expect(stub.user.authProvider == "duo-oidc")
            #expect(stub.user.externalSubject == nil)

            // What the admin's first DUO sign-in does to the stub: it takes
            // the subject, and the SSO admin allowlist sets the role.
            stub.user.externalSubject = "duo-subject-root"
            stub.user.role = UserRole.admin.rawValue
            try await stub.user.save(on: app.db)

            await #expect(throws: LTIIdentityResolver.Failure.linkRefused(username: "root")) {
                _ = try await self.resolve(try self.launch(username: "root"), platform, authMode: .sso)
            }
        }
    }

    @Test func aLinkedAccountThatStaysAUserStillSignsIn() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(trustUsername: false)
            let first = try await resolve(try launch(), platform)
            let again = try await resolve(try launch(), platform)
            #expect(!again.created)
            #expect(again.user.id == first.user.id)
        }
    }
}
