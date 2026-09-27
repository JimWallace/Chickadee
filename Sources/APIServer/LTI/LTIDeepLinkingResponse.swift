// APIServer/LTI/LTIDeepLinkingResponse.swift
//
// The signed `LtiDeepLinkingResponse` Chickadee returns to the platform
// (docs/lti-1-3.md "Deep Linking"). The tool is the issuer (its client ID)
// and the platform the audience; the tool key signs it, and the platform
// verifies it against `GET /lti/jwks`.

import Foundation
import JWT

struct LTIDeepLinkingResponse: JWTPayload, Equatable {
    /// One `ltiResourceLink` the platform turns into a link. Its launch
    /// carries `custom.assignment`, which the launch route follows.
    struct ContentItem: Codable, Equatable, Sendable {
        let type: String
        let title: String
        let url: String
        let custom: [String: String]
    }

    /// How long the response stays valid: the platform receives it at once.
    static let lifetime: TimeInterval = 300

    let iss: IssuerClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let nonce: String
    let messageType: String
    let version: String
    let deploymentID: String
    let data: String?
    let contentItems: [ContentItem]

    enum CodingKeys: String, CodingKey {
        case iss, aud, exp, iat, nonce
        case messageType = "https://purl.imsglobal.org/spec/lti/claim/message_type"
        case version = "https://purl.imsglobal.org/spec/lti/claim/version"
        case deploymentID = "https://purl.imsglobal.org/spec/lti/claim/deployment_id"
        case data = "https://purl.imsglobal.org/spec/lti-dl/claim/data"
        case contentItems = "https://purl.imsglobal.org/spec/lti-dl/claim/content_items"
    }

    init(
        clientID: String, platformIssuer: String, deploymentID: String, data: String?,
        contentItems: [ContentItem], now: Date = Date()
    ) {
        self.iss = IssuerClaim(value: clientID)
        self.aud = AudienceClaim(value: [platformIssuer])
        self.exp = ExpirationClaim(value: now.addingTimeInterval(Self.lifetime))
        self.iat = IssuedAtClaim(value: now)
        self.nonce = LTILaunchSecrets.randomToken()
        self.messageType = "LtiDeepLinkingResponse"
        self.version = LTILaunchValidator.supportedVersion
        self.deploymentID = deploymentID
        self.data = data
        self.contentItems = contentItems
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
