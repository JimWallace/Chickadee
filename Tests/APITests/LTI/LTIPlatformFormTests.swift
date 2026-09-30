// Tests/APITests/LTI/LTIPlatformFormTests.swift
//
// One test per `LTIPlatformForm.validated()` rule (docs/lti-1-3.md slice 1b),
// each breaking exactly one field of a form that otherwise passes. The passing
// form is asserted too, so no refusal can be green because the fixture was
// already invalid.

import Foundation
import Testing

@testable import APIServer

@Suite struct LTIPlatformFormTests {
    static let valid = LTIPlatformForm(
        displayName: " UW LEARN ",
        issuer: "https://learn.example.edu",
        clientID: " client-1 ",
        deploymentIDs: "deployment-1\n\n  deployment-2  \ndeployment-1\r\n",
        authLoginURL: "https://learn.example.edu/d2l/lti/authenticate",
        accessTokenURL: "https://auth.example.edu/core/connect/token",
        jwksURL: "https://learn.example.edu/d2l/.well-known/jwks")

    private func expectRefusal(_ expected: LTIPlatformFormError, _ change: (inout LTIPlatformForm) -> Void) {
        var form = Self.valid
        change(&form)
        #expect(throws: expected) { try form.validated() }
    }

    @Test func validFormIsTrimmedAndDeploymentsDeduplicatedInOrder() throws {
        let valid = try Self.valid.validated()
        #expect(valid.displayName == "UW LEARN")
        #expect(valid.clientID == "client-1")
        #expect(valid.deploymentIDs == ["deployment-1", "deployment-2"])
        #expect(valid.issuer == "https://learn.example.edu")
    }

    @Test func blankTokenAudienceIsStoredAsNil() throws {
        var form = Self.valid
        form.tokenAudience = "   "
        #expect(try form.validated().tokenAudience == nil)
        form.tokenAudience = nil
        #expect(try form.validated().tokenAudience == nil)
    }

    @Test func tokenAudienceIsTrimmedAndNotHeldToTheURLRules() throws {
        var form = Self.valid
        form.tokenAudience = "  https://api.brightspace.com/auth/token \n"
        #expect(try form.validated().tokenAudience == "https://api.brightspace.com/auth/token")
        form.tokenAudience = "urn:example:audience"
        #expect(try form.validated().tokenAudience == "urn:example:audience")
    }

    @Test func missingNameIsRefused() {
        expectRefusal(.missingDisplayName) { $0.displayName = "  " }
    }

    @Test func missingClientIDIsRefused() {
        expectRefusal(.missingClientID) { $0.clientID = "" }
    }

    @Test func missingDeploymentIsRefused() {
        expectRefusal(.missingDeploymentID) { $0.deploymentIDs = " \n \n" }
    }

    @Test(arguments: ["", "not a url", "/relative/path", "https://"])
    func unparsableIssuerIsRefused(issuer: String) {
        expectRefusal(.invalidURL(.issuer)) { $0.issuer = issuer }
    }

    @Test func plainHTTPIsRefusedForARemoteHost() {
        expectRefusal(.insecureURL(.jwksURL)) { $0.jwksURL = "http://learn.example.edu/jwks" }
        expectRefusal(.insecureURL(.authLoginURL)) { $0.authLoginURL = "http://learn.example.edu/auth" }
        expectRefusal(.insecureURL(.accessTokenURL)) { $0.accessTokenURL = "ftp://learn.example.edu/token" }
    }

    @Test(arguments: ["http://localhost:9000/jwks", "http://127.0.0.1/jwks"])
    func plainHTTPIsAcceptedForALoopbackTestPlatform(url: String) throws {
        var form = Self.valid
        form.jwksURL = url
        #expect(try form.validated().jwksURL == url)
    }

    @Test func everyRefusalHasASentence() {
        let errors: [LTIPlatformFormError] = [
            .missingDisplayName, .missingClientID, .missingDeploymentID,
            .invalidURL(.issuer), .insecureURL(.jwksURL), .duplicate,
        ]
        for error in errors {
            #expect(error.message.hasSuffix("."))
            #expect(!error.message.contains("!"))
        }
    }
}
