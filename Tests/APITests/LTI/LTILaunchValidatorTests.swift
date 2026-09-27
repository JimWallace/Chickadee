// Tests/APITests/LTI/LTILaunchValidatorTests.swift
//
// One negative test per `LTILaunchValidator` rule (docs/lti-1-3.md "Launch
// validation"), each starting from a launch that passes and breaking exactly
// one claim, so a test fails only for the rule it names. The passing launch is
// asserted too: without it every negative test could be green because the
// fixture was invalid from the start.

import Core
import Foundation
import JWT
import Testing

@testable import APIServer

@Suite struct LTILaunchValidatorTests {
    static let issuer = "https://lms.example.edu"
    static let clientID = "chickadee-client"
    static let deploymentID = "deployment-1"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let learner = "http://purl.imsglobal.org/vocab/lis/v2/membership#Learner"

    let platform = LTIPlatformRegistration(
        issuer: issuer, clientID: clientID, deploymentIDs: [deploymentID])

    /// A resource-link launch that passes every rule; each test changes one claim.
    struct Launch {
        var iss = LTILaunchValidatorTests.issuer
        var sub: String? = "user-123"
        var aud = [LTILaunchValidatorTests.clientID]
        var azp: String?
        var exp = LTILaunchValidatorTests.now.addingTimeInterval(300)
        var iat = LTILaunchValidatorTests.now
        var nonce: String? = "nonce-abc"
        var messageType: String? = "LtiResourceLinkRequest"
        var version: String? = "1.3.0"
        var deploymentID: String? = LTILaunchValidatorTests.deploymentID
        var roles: [String]? = [LTILaunchValidatorTests.learner]
        var context: LTILaunchClaims.Context? = .init(id: "ctx-1", label: "CS 135", title: nil)
        var resourceLink: LTILaunchClaims.ResourceLink? = .init(id: "rl-1", title: "Lab 1")

        var claims: LTILaunchClaims {
            LTILaunchClaims(
                iss: IssuerClaim(value: iss),
                sub: sub.map { SubjectClaim(value: $0) },
                aud: AudienceClaim(value: aud),
                exp: ExpirationClaim(value: exp),
                iat: IssuedAtClaim(value: iat),
                nonce: nonce,
                azp: azp,
                name: "Ada Lovelace",
                email: "ada@example.edu",
                messageType: messageType,
                version: version,
                deploymentID: deploymentID,
                targetLinkURI: nil,
                roles: roles,
                context: context,
                resourceLink: resourceLink,
                custom: ["username": .string("alovelace")]
            )
        }
    }

    private func validate(_ launch: Launch) throws(LTILaunchError) -> LTIValidatedLaunch {
        try LTILaunchValidator.validate(launch.claims, against: platform, now: Self.now)
    }

    private func expectRefusal(_ expected: LTILaunchError, _ change: (inout Launch) -> Void) {
        var launch = Launch()
        change(&launch)
        #expect(throws: expected) { try validate(launch) }
    }

    @Test func validResourceLinkLaunchPasses() throws {
        let launch = try validate(Launch())
        #expect(launch.messageType == .resourceLink)
        #expect(launch.subject == "user-123")
        #expect(launch.nonce == "nonce-abc")
        #expect(launch.deploymentID == Self.deploymentID)
        #expect(launch.courseRole == .student)
        #expect(launch.context?.id == "ctx-1")
        #expect(launch.resourceLink?.id == "rl-1")
        #expect(launch.custom["username"] == .string("alovelace"))
    }

    @Test func deepLinkingLaunchNeedsNoResourceLink() throws {
        var launch = Launch()
        launch.messageType = "LtiDeepLinkingRequest"
        launch.resourceLink = nil
        launch.roles = ["http://purl.imsglobal.org/vocab/lis/v2/membership#Instructor"]
        let validated = try validate(launch)
        #expect(validated.messageType == .deepLinking)
        #expect(validated.courseRole == .instructor)
    }

    @Test func multipleAudiencesPassWhenAuthorizedPartyNamesTheTool() throws {
        var launch = Launch()
        launch.aud = [Self.clientID, "another-tool"]
        launch.azp = Self.clientID
        #expect(try validate(launch).subject == "user-123")
    }

    @Test func clockSkewWithinSixtySecondsIsAccepted() throws {
        var launch = Launch()
        launch.exp = Self.now.addingTimeInterval(-30)
        launch.iat = Self.now.addingTimeInterval(30)
        #expect(try validate(launch).subject == "user-123")
    }

    @Test func wrongIssuerIsRefused() {
        expectRefusal(.issuerMismatch) { $0.iss = "https://evil.example" }
    }

    @Test func audienceWithoutTheClientIDIsRefused() {
        expectRefusal(.audienceMismatch) { $0.aud = ["another-tool"] }
    }

    @Test func multipleAudiencesWithoutAuthorizedPartyAreRefused() {
        expectRefusal(.authorizedPartyMismatch) { $0.aud = [Self.clientID, "another-tool"] }
    }

    @Test func authorizedPartyNamingAnotherToolIsRefused() {
        expectRefusal(.authorizedPartyMismatch) { $0.azp = "another-tool" }
    }

    @Test func unregisteredDeploymentIsRefused() {
        expectRefusal(.unknownDeployment) { $0.deploymentID = "deployment-2" }
    }

    @Test func missingDeploymentIsRefused() {
        expectRefusal(.unknownDeployment) { $0.deploymentID = nil }
    }

    @Test(arguments: [nil, "1.1", "1.3"])
    func unsupportedVersionIsRefused(version: String?) {
        expectRefusal(.unsupportedVersion) { $0.version = version }
    }

    @Test(arguments: [nil, "LtiSubmissionReviewRequest", "basic-lti-launch-request"])
    func unsupportedMessageTypeIsRefused(messageType: String?) {
        expectRefusal(.unsupportedMessageType) { $0.messageType = messageType }
    }

    @Test(arguments: [nil, "", "  "])
    func missingNonceIsRefused(nonce: String?) {
        expectRefusal(.missingNonce) { $0.nonce = nonce }
    }

    @Test(arguments: [nil, ""])
    func anonymousLaunchIsRefused(subject: String?) {
        expectRefusal(.missingSubject) { $0.sub = subject }
    }

    @Test func expiredLaunchIsRefused() {
        expectRefusal(.expired) { $0.exp = Self.now.addingTimeInterval(-61) }
    }

    @Test func launchIssuedInTheFutureIsRefused() {
        expectRefusal(.issuedInFuture) { $0.iat = Self.now.addingTimeInterval(61) }
    }

    @Test func resourceLinkLaunchWithoutContextIsRefused() {
        expectRefusal(.missingContext) { $0.context = nil }
    }

    @Test func resourceLinkLaunchWithEmptyContextIDIsRefused() {
        expectRefusal(.missingContext) { $0.context = .init(id: " ", label: nil, title: nil) }
    }

    @Test func resourceLinkLaunchWithoutResourceLinkIsRefused() {
        expectRefusal(.missingResourceLink) { $0.resourceLink = nil }
    }

    @Test func launchWithNoMappableRoleIsRefused() {
        expectRefusal(.noCourseRole) {
            $0.roles = ["http://purl.imsglobal.org/vocab/lis/v2/institution/person#Instructor"]
        }
    }

    @Test func launchWithNoRolesClaimIsRefused() {
        expectRefusal(.noCourseRole) { $0.roles = nil }
    }
}
