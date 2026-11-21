// APIServer/Auth/OIDCIDTokenClaims.swift
//
// JWT payload struct for OIDC ID tokens.
//
// Standard claims (sub, iss, aud, exp, iat) are declared using JWTKit wrapper
// types. Well-known OIDC profile claims (name, email, etc.) are plain optionals.
// Any other claims — including IdP-specific ones like winaccountname or user_id —
// are captured in `extraClaims` and accessible via `value(for:)`.
//
// Which claim to use for the Chickadee username is configured via
// OIDC_USERNAME_CLAIM (see OIDCClaimConfig). This removes the hard dependency
// on UWaterloo DUO's winaccountname claim.
//
// Signature verification and exp validation are performed by JWTKit when
// app.jwt.keys.verify(_:as:) is called. The other ID token rules of OIDC Core
// 3.1.3.7 (issuer, audience, azp, iat, nonce) are checked by `validate(...)`,
// which SSOAuthRoutes.ssoCallback calls after decoding.

import Foundation
import JWT

struct OIDCIDTokenClaims: JWTPayload, Sendable {

    // MARK: Standard claims

    var sub: SubjectClaim
    var iss: IssuerClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var iat: IssuedAtClaim

    // MARK: Well-known OIDC profile claims

    /// Full display name, e.g. "Jane Doe"
    var name: String?

    /// Preferred/given first name
    var preferredName: String?  // "preferred_name"
    var givenName: String?  // "given_name"
    var familyName: String?  // "family_name"

    var preferredUsername: String?  // "preferred_username" (standard OIDC)
    var email: String?

    // MARK: Request-binding claims

    /// The `nonce` value sent on the authorization request, echoed by the IdP.
    var nonce: String?
    /// Authorized party: the client the token was issued to ("azp").
    var azp: String?

    // MARK: Extra / IdP-specific claims

    /// All JWT claims not covered by the declared fields above.
    /// Accessed via `value(for:)` using the claim's JSON key name.
    /// Values are stored as strings; non-string JSON values are ignored.
    var extraClaims: [String: String]

    // MARK: Claim lookup

    /// Returns the string value of any claim by its JWT key name.
    /// Covers both declared fields and IdP-specific extras (e.g. "winaccountname").
    func value(for claimName: String) -> String? {
        switch claimName {
        case "sub": return sub.value
        case "email": return email
        case "name": return name
        case "preferred_name": return preferredName
        case "given_name": return givenName
        case "family_name": return familyName
        case "preferred_username": return preferredUsername
        default: return extraClaims[claimName]
        }
    }

    // MARK: JWTPayload

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.exp.verifyNotExpired()
    }

    // MARK: Custom Codable

    // Known keys decoded into typed fields. Everything else goes into extraClaims.
    private enum KnownKey: String, CodingKey, CaseIterable {
        case sub, iss, aud, exp, iat
        case name
        case preferredName = "preferred_name"
        case givenName = "given_name"
        case familyName = "family_name"
        case preferredUsername = "preferred_username"
        case email
        case nonce, azp
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: KnownKey.self)
        sub = try c.decode(SubjectClaim.self, forKey: .sub)
        iss = try c.decode(IssuerClaim.self, forKey: .iss)
        aud = try c.decode(AudienceClaim.self, forKey: .aud)
        exp = try c.decode(ExpirationClaim.self, forKey: .exp)
        iat = try c.decode(IssuedAtClaim.self, forKey: .iat)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        preferredName = try c.decodeIfPresent(String.self, forKey: .preferredName)
        givenName = try c.decodeIfPresent(String.self, forKey: .givenName)
        familyName = try c.decodeIfPresent(String.self, forKey: .familyName)
        preferredUsername = try c.decodeIfPresent(String.self, forKey: .preferredUsername)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        azp = try c.decodeIfPresent(String.self, forKey: .azp)

        // Capture remaining string-valued claims into extraClaims.
        let all = try decoder.container(keyedBy: RawStringKey.self)
        let knownKeyStrings = Set(KnownKey.allCases.map(\.rawValue))
        var extras: [String: String] = [:]
        for key in all.allKeys where !knownKeyStrings.contains(key.stringValue) {
            if let str = try? all.decode(String.self, forKey: key) {
                extras[key.stringValue] = str
            }
        }
        extraClaims = extras
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: KnownKey.self)
        try c.encode(sub, forKey: .sub)
        try c.encode(iss, forKey: .iss)
        try c.encode(aud, forKey: .aud)
        try c.encode(exp, forKey: .exp)
        try c.encode(iat, forKey: .iat)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(preferredName, forKey: .preferredName)
        try c.encodeIfPresent(givenName, forKey: .givenName)
        try c.encodeIfPresent(familyName, forKey: .familyName)
        try c.encodeIfPresent(preferredUsername, forKey: .preferredUsername)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(nonce, forKey: .nonce)
        try c.encodeIfPresent(azp, forKey: .azp)
        var extras = encoder.container(keyedBy: RawStringKey.self)
        for (key, value) in extraClaims {
            try extras.encode(value, forKey: RawStringKey(key))
        }
    }
}

// MARK: - ID token validation (OIDC Core 3.1.3.7)

extension OIDCIDTokenClaims {
    /// How far in the future `iat` may be before the token is refused, to
    /// allow for clock skew between the IdP and this server.
    static let allowedIssuedAtSkew: TimeInterval = 300

    /// Checks the claims that JWTKit does not: the issuer, the audience, the
    /// authorized party, the issue time and the nonce that binds the token to
    /// this browser's login. The signature and `exp` are already verified.
    func validate(
        issuer expectedIssuer: String,
        clientID: String,
        expectedNonce: String,
        now: Date = Date()
    ) throws(OIDCIDTokenRefusal) {
        guard iss.value == expectedIssuer else { throw .issuerMismatch }
        guard aud.value.contains(clientID) else { throw .audienceMismatch }
        // OIDC Core 3.1.3.7 items 4 and 5: a token for several audiences must
        // name this client as its authorized party, and any azp must be us.
        if let azp {
            guard azp == clientID else { throw .authorizedPartyMismatch }
        } else if aud.value.count > 1 {
            throw .authorizedPartyMissing
        }
        guard iat.value <= now.addingTimeInterval(Self.allowedIssuedAtSkew) else {
            throw .issuedInFuture
        }
        guard !expectedNonce.isEmpty, nonce == expectedNonce else { throw .nonceMismatch }
    }
}

// MARK: - Memberwise init (for constructing tokens in tests and signing)

extension OIDCIDTokenClaims {
    init(
        sub: SubjectClaim,
        iss: IssuerClaim,
        aud: AudienceClaim,
        exp: ExpirationClaim,
        iat: IssuedAtClaim,
        name: String? = nil,
        preferredName: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil,
        preferredUsername: String? = nil,
        email: String? = nil,
        nonce: String? = nil,
        azp: String? = nil,
        extraClaims: [String: String] = [:]
    ) {
        self.sub = sub
        self.iss = iss
        self.aud = aud
        self.exp = exp
        self.iat = iat
        self.name = name
        self.preferredName = preferredName
        self.givenName = givenName
        self.familyName = familyName
        self.preferredUsername = preferredUsername
        self.email = email
        self.nonce = nonce
        self.azp = azp
        self.extraClaims = extraClaims
    }
}

// MARK: - Dynamic string coding key

private struct RawStringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
