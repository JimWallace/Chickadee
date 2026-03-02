// APIServer/Auth/OIDCIDTokenClaims.swift
//
// JWT payload struct for UWaterloo DUO OIDC ID tokens.
//
// Standard claims (sub, iss, aud, exp, iat) are declared using JWTKit wrapper
// types. UWaterloo-specific claims (winaccountname, given_name, family_name)
// are plain optionals decoded from the JWT body.
//
// Signature verification and exp validation are performed by JWTKit when
// app.jwt.keys.verify(_:as:) is called. Issuer and audience are checked
// manually in SSOAuthRoutes.ssoCallback after decoding.

import JWT
import Foundation

struct OIDCIDTokenClaims: JWTPayload, Sendable {

    // MARK: Standard claims

    var sub: SubjectClaim
    var iss: IssuerClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var iat: IssuedAtClaim

    // MARK: UWaterloo DUO OIDC claims

    /// WatIAM username (e.g. "jdoe"). Used as the local username for new SSO users.
    var winaccountname: String?

    /// Display name, e.g. "Jane Doe"
    var name: String?

    /// Preferred name, e.g. "Jane"
    var preferredName: String? // "preferred_name"

    var givenName: String?   // "given_name"
    var familyName: String?  // "family_name"

    /// Institution account/user identifier.
    var userID: String? // "user_id"

    /// Student identifier.
    var studentID: String? // "student_id"

    var email: String?

    // MARK: Coding keys

    enum CodingKeys: String, CodingKey {
        case sub, iss, aud, exp, iat
        case winaccountname
        case name
        case preferredName = "preferred_name"
        case givenName   = "given_name"
        case familyName  = "family_name"
        case userID      = "user_id"
        case studentID   = "student_id"
        case email
    }

    // MARK: JWTPayload

    func verify(using algorithm: some JWTAlgorithm) async throws {
        // exp is the only claim that requires active validation here;
        // the signature has already been checked by JWTKit before this is called.
        // Issuer and audience are validated in the route handler.
        try self.exp.verifyNotExpired()
    }
}
