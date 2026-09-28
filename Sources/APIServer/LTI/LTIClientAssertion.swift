// APIServer/LTI/LTIClientAssertion.swift
//
// The JWT a tool signs to ask a platform for an access token (the IMS
// Security Framework client-credentials grant): Chickadee's client ID as
// both issuer and subject, the token URL as audience, and a single-use `jti`.

import Foundation
import JWT

struct LTIClientAssertion: JWTPayload, Equatable {
    /// How long the assertion is valid. The platform uses it at once.
    static let lifetime: TimeInterval = 300

    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let iat: IssuedAtClaim
    let exp: ExpirationClaim
    let jti: IDClaim

    init(clientID: String, audience: String, issuedAt: Date) {
        iss = IssuerClaim(value: clientID)
        sub = SubjectClaim(value: clientID)
        aud = AudienceClaim(value: audience)
        iat = IssuedAtClaim(value: issuedAt)
        exp = ExpirationClaim(value: issuedAt.addingTimeInterval(Self.lifetime))
        jti = IDClaim(value: UUID().uuidString)
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
