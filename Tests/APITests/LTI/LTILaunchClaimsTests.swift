// Tests/APITests/LTI/LTILaunchClaimsTests.swift
//
// Decoding of a launch `id_token` payload. The LTI claims ride URI-named keys,
// so a typo in one coding key would decode as nil and surface only as a
// refused launch in production; these tests read a realistic payload.

import Core
import Foundation
import JWT
import Testing

@testable import APIServer

@Suite struct LTILaunchClaimsTests {
    static let payload = """
        {
          "iss": "https://lms.example.edu",
          "sub": "user-123",
          "aud": "chickadee-client",
          "exp": 1800000300,
          "iat": 1800000000,
          "nonce": "nonce-abc",
          "name": "Ada Lovelace",
          "email": "ada@example.edu",
          "https://purl.imsglobal.org/spec/lti/claim/message_type": "LtiResourceLinkRequest",
          "https://purl.imsglobal.org/spec/lti/claim/version": "1.3.0",
          "https://purl.imsglobal.org/spec/lti/claim/deployment_id": "deployment-1",
          "https://purl.imsglobal.org/spec/lti/claim/target_link_uri": "https://chickadee.example/lti/launch",
          "https://purl.imsglobal.org/spec/lti/claim/roles": [
            "http://purl.imsglobal.org/vocab/lis/v2/membership#Learner"
          ],
          "https://purl.imsglobal.org/spec/lti/claim/context": {
            "id": "6606", "label": "CS 135", "title": "Designing Functional Programs",
            "type": ["http://purl.imsglobal.org/vocab/lis/v2/course#CourseOffering"]
          },
          "https://purl.imsglobal.org/spec/lti/claim/resource_link": {"id": "rl-1", "title": "Lab 1"},
          "https://purl.imsglobal.org/spec/lti/claim/custom": {"username": "alovelace", "attempt": 2},
          "https://purl.imsglobal.org/spec/lti/claim/tool_platform": {"name": "LEARN"}
        }
        """

    /// Decodes the way JWTKit's `defaultForJWT` decoder does for a verified
    /// token: dates are seconds since 1970, not Foundation's reference date.
    static func decode() throws -> LTILaunchClaims {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(LTILaunchClaims.self, from: Data(payload.utf8))
    }

    @Test func decodesAResourceLinkLaunch() throws {
        let claims = try Self.decode()
        #expect(claims.iss.value == "https://lms.example.edu")
        #expect(claims.sub?.value == "user-123")
        #expect(claims.aud.value == ["chickadee-client"])
        #expect(claims.exp.value == Date(timeIntervalSince1970: 1_800_000_300))
        #expect(claims.messageType == "LtiResourceLinkRequest")
        #expect(claims.version == "1.3.0")
        #expect(claims.deploymentID == "deployment-1")
        #expect(claims.targetLinkURI == "https://chickadee.example/lti/launch")
        #expect(claims.roles == ["http://purl.imsglobal.org/vocab/lis/v2/membership#Learner"])
        #expect(claims.context == .init(id: "6606", label: "CS 135", title: "Designing Functional Programs"))
        #expect(claims.resourceLink == .init(id: "rl-1", title: "Lab 1"))
        #expect(claims.name == "Ada Lovelace")
        #expect(claims.email == "ada@example.edu")
    }

    /// One non-string custom value must not make the launch undecodable.
    @Test func keepsNonStringCustomParameters() throws {
        let claims = try Self.decode()
        #expect(claims.custom?["username"] == .string("alovelace"))
        #expect(claims.custom?["attempt"] != nil)
    }

    /// The decoded payload passes the validator end to end, which proves the
    /// coding keys and the validator agree on what a launch looks like.
    @Test func decodedLaunchPassesTheValidator() throws {
        let claims = try Self.decode()
        let platform = LTIPlatformRegistration(
            issuer: "https://lms.example.edu", clientID: "chickadee-client", deploymentIDs: ["deployment-1"])
        let launch = try LTILaunchValidator.validate(
            claims, against: platform, now: Date(timeIntervalSince1970: 1_800_000_010))
        #expect(launch.courseRole == .student)
        #expect(launch.context?.id == "6606")
    }
}
