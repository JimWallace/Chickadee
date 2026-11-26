// APIServer/LTI/LTILaunchClaims.swift
//
// The claims of an LTI 1.3 launch `id_token` that Chickadee reads
// (docs/lti-1-3.md "Launch validation"). Everything LTI-specific rides a
// URI-named claim, hence the explicit coding keys.

import Core
import Foundation
import JWT

struct LTILaunchClaims: JWTPayload, Equatable {
    /// `exp`, `iat` and `nbf` are checked with this much clock skew either way.
    static let clockSkewSeconds: TimeInterval = 60

    /// A launch whose `iat` is older than this (plus the skew) is refused even
    /// when `exp` says otherwise. It equals the login state's lifetime: a
    /// token issued before the login that it answers cannot be genuine.
    static let maximumAgeSeconds: TimeInterval = APILTILoginState.lifetime

    struct Context: Codable, Equatable, Sendable {
        let id: String
        let label: String?
        let title: String?
    }

    struct ResourceLink: Codable, Equatable, Sendable {
        let id: String
        let title: String?
    }

    let iss: IssuerClaim
    let sub: SubjectClaim?
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let nonce: String?
    let azp: String?
    let name: String?
    let email: String?

    let messageType: String?
    let version: String?
    let deploymentID: String?
    let targetLinkURI: String?
    let roles: [String]?
    let context: Context?
    let resourceLink: ResourceLink?
    /// Platform custom parameters. Values are kept as `JSONValue` because a
    /// platform may send a number or boolean, and one non-string value must
    /// not make the whole launch undecodable.
    let custom: [String: JSONValue]?
    /// Present on an `LtiDeepLinkingRequest`. Last and defaulted, so a launch
    /// built without it (every resource-link launch) needs no change.
    var deepLinkingSettings: LTIDeepLinkingSettings?
    /// The AGS endpoint, on a launch from a platform that grants AGS.
    var agsEndpoint: LTIAGSEndpoint?
    /// The NRPS endpoint, on a launch from a platform that grants NRPS.
    var nrpsEndpoint: LTINRPSEndpoint?
    /// Optional in OIDC; checked when a platform sends it. Last and
    /// defaulted for the same reason as `deepLinkingSettings`.
    var nbf: NotBeforeClaim?

    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nbf, nonce, azp, name, email
        case messageType = "https://purl.imsglobal.org/spec/lti/claim/message_type"
        case version = "https://purl.imsglobal.org/spec/lti/claim/version"
        case deploymentID = "https://purl.imsglobal.org/spec/lti/claim/deployment_id"
        case targetLinkURI = "https://purl.imsglobal.org/spec/lti/claim/target_link_uri"
        case roles = "https://purl.imsglobal.org/spec/lti/claim/roles"
        case context = "https://purl.imsglobal.org/spec/lti/claim/context"
        case resourceLink = "https://purl.imsglobal.org/spec/lti/claim/resource_link"
        case custom = "https://purl.imsglobal.org/spec/lti/claim/custom"
        case deepLinkingSettings = "https://purl.imsglobal.org/spec/lti-dl/claim/deep_linking_settings"
        case agsEndpoint = "https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"
        case nrpsEndpoint = "https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice"
    }

    /// Signature-time check: expiry only, with clock skew. The full rule set,
    /// with an injectable clock, is `LTILaunchValidator`, which every launch
    /// runs after this.
    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired(currentDate: Date().addingTimeInterval(-Self.clockSkewSeconds))
    }
}
