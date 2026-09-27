// Tests/APITests/LTI/LTITestPlatform.swift
//
// A stand-in LMS for the launch tests (docs/lti-1-3.md "Slice plan"): it
// owns an RSA key the test controls, serves its key set through the app's
// platform key cache, registers itself, and signs launch id_tokens.

import Core
import Fluent
import Foundation
import JWT
import Vapor

@testable import APIServer

struct LTITestPlatform {
    static let issuer = "https://lms.example.edu"
    static let clientID = "chickadee-client"
    static let deploymentID = "deployment-1"
    static let authLoginURL = "https://lms.example.edu/auth"
    static let learner = "http://purl.imsglobal.org/vocab/lis/v2/membership#Learner"
    static let instructor = "http://purl.imsglobal.org/vocab/lis/v2/membership#Instructor"

    let signer: LTIToolKeyAuthority
    let directory: URL

    /// A platform with a fresh key in its own temporary directory.
    static func make() async throws -> LTITestPlatform {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-platform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let signer = try await LTIToolKeyAuthority.loadOrGenerate(
            path: directory.appendingPathComponent("platform-key").path)
        return LTITestPlatform(signer: signer, directory: directory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    func jwksJSON() async throws -> String {
        let data = try JSONEncoder().encode(["keys": [await signer.publicJWK()]])
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Registers the platform and points the app's key cache at this key.
    @discardableResult
    func install(
        on app: Application, trustUsername: Bool = false, enabled: Bool = true
    ) async throws
        -> APILTIPlatform
    {
        let json = try await jwksJSON()
        app.ltiPlatformKeyCache = LTIPlatformKeyCache { _ in json }
        let platform = APILTIPlatform(
            issuer: Self.issuer, clientID: Self.clientID, deploymentIDs: [Self.deploymentID],
            authLoginURL: Self.authLoginURL, accessTokenURL: "https://lms.example.edu/token",
            jwksURL: "https://lms.example.edu/jwks", displayName: "Test LMS", enabled: enabled)
        platform.trustUsername = trustUsername
        try await platform.save(on: app.db)
        return platform
    }

    /// Launch claims that pass every rule for this platform.
    static func claims(
        nonce: String,
        subject: String = "subject-1",
        roles: [String] = [learner],
        contextID: String = "context-1",
        messageType: String = "LtiResourceLinkRequest",
        custom: [String: JSONValue] = [:],
        issuedAt: Date = Date()
    ) -> LTILaunchClaims {
        LTILaunchClaims(
            iss: IssuerClaim(value: issuer),
            sub: SubjectClaim(value: subject),
            aud: AudienceClaim(value: [clientID]),
            exp: ExpirationClaim(value: issuedAt.addingTimeInterval(300)),
            iat: IssuedAtClaim(value: issuedAt),
            nonce: nonce,
            azp: nil,
            name: "Ada Lovelace",
            email: "ada@example.edu",
            messageType: messageType,
            version: "1.3.0",
            deploymentID: deploymentID,
            targetLinkURI: "http://localhost/lti/launch",
            roles: roles,
            context: .init(id: contextID, label: "CS 135", title: "Designing Functional Programs"),
            resourceLink: .init(id: "link-1", title: "Lab 1"),
            custom: custom)
    }

    func sign(_ claims: LTILaunchClaims) async throws -> String {
        try await signer.sign(claims)
    }
}
