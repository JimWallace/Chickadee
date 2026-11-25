// Tests/APITests/LTI/LTILaunchTokenHardeningTests.swift
//
// The launch-token rules that docs/compliance/lti-audit-2026-10.md L-6 found
// untested or missing: a token signed with no algorithm or with HS256 is
// refused by the platform key cache, a token older than the login state's
// lifetime is refused, and a token whose `nbf` is still in the future is
// refused. Each refusal is paired with a token that passes, so a broken
// fixture cannot make the refusal green.

import Foundation
import JWT
import Testing

@testable import APIServer

@Suite struct LTILaunchTokenHardeningTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    let platform = LTIPlatformRegistration(
        issuer: LTITestPlatform.issuer, clientID: LTITestPlatform.clientID,
        deploymentIDs: [LTITestPlatform.deploymentID])

    private func claims(issuedAt: Date = now, notBefore: Date? = nil) -> LTILaunchClaims {
        var claims = LTITestPlatform.claims(nonce: "n", issuedAt: issuedAt)
        claims.nbf = notBefore.map { NotBeforeClaim(value: $0) }
        return claims
    }

    private func validate(_ claims: LTILaunchClaims) throws(LTILaunchError) -> LTIValidatedLaunch {
        try LTILaunchValidator.validate(claims, against: platform, now: Self.now)
    }

    // MARK: - Token age

    @Test func tokenAtTheMaximumAgeIsAccepted() throws {
        let age = LTILaunchClaims.maximumAgeSeconds + LTILaunchClaims.clockSkewSeconds
        // `exp` follows `iat` in the fixture; keep it in the future.
        let launch = LTILaunchClaims(
            copying: claims(issuedAt: Self.now.addingTimeInterval(-age)),
            expiresAt: Self.now.addingTimeInterval(60))
        #expect(try validate(launch).subject == "subject-1")
    }

    @Test func tokenOlderThanTheMaximumAgeIsRefused() {
        let age = LTILaunchClaims.maximumAgeSeconds + LTILaunchClaims.clockSkewSeconds + 1
        let launch = LTILaunchClaims(
            copying: claims(issuedAt: Self.now.addingTimeInterval(-age)),
            expiresAt: Self.now.addingTimeInterval(60))
        #expect(throws: LTILaunchError.issuedTooLongAgo) { try validate(launch) }
    }

    // MARK: - nbf

    @Test func pastNotBeforeIsAccepted() throws {
        #expect(try validate(claims(notBefore: Self.now.addingTimeInterval(-10))).subject == "subject-1")
    }

    @Test func notBeforeWithinTheSkewIsAccepted() throws {
        #expect(try validate(claims(notBefore: Self.now.addingTimeInterval(30))).subject == "subject-1")
    }

    @Test func futureNotBeforeIsRefused() {
        let launch = claims(notBefore: Self.now.addingTimeInterval(LTILaunchClaims.clockSkewSeconds + 1))
        #expect(throws: LTILaunchError.notYetValid) { try validate(launch) }
    }

    // MARK: - Algorithm

    /// The key cache serving the test platform's RSA key set.
    private func keyCache(for platform: LTITestPlatform) async throws -> LTIPlatformKeyCache {
        let json = try await platform.jwksJSON()
        return LTIPlatformKeyCache { _ in json }
    }

    @Test func rs256TokenFromThePlatformVerifies() async throws {
        let platform = try await LTITestPlatform.make()
        defer { platform.cleanUp() }
        let cache = try await keyCache(for: platform)
        let token = try await platform.sign(LTITestPlatform.claims(nonce: "rs256"))
        let verified = try await cache.verify(token, platformID: UUID(), jwksURL: "u")
        #expect(verified.nonce == "rs256")
    }

    @Test func tokenWithNoAlgorithmIsRefused() async throws {
        let platform = try await LTITestPlatform.make()
        defer { platform.cleanUp() }
        let cache = try await keyCache(for: platform)
        // A genuine payload, re-sent with `alg: none` and no signature.
        let signed = try await platform.sign(LTITestPlatform.claims(nonce: "none"))
        let payload = try #require(signed.split(separator: ".").dropFirst().first)
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "\(header).\(payload)."
        await #expect(throws: (any Error).self) {
            _ = try await cache.verify(token, platformID: UUID(), jwksURL: "u")
        }
    }

    @Test func hs256TokenNamingThePlatformKeyIsRefused() async throws {
        let platform = try await LTITestPlatform.make()
        defer { platform.cleanUp() }
        let cache = try await keyCache(for: platform)
        // The key-confusion attack: an HMAC signature keyed with the public
        // key, under the platform key's `kid`.
        let jwk = await platform.signer.publicJWK()
        let kid = try #require(jwk["kid"])
        let secret = try #require(jwk["n"])
        let forger = await JWTKeyCollection().add(
            hmac: HMACKey(from: secret), digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))
        let token = try await forger.sign(LTITestPlatform.claims(nonce: "hs256"), kid: JWKIdentifier(string: kid))
        await #expect(throws: (any Error).self) {
            _ = try await cache.verify(token, platformID: UUID(), jwksURL: "u")
        }
    }
}

extension LTILaunchClaims {
    /// `claims` with another `exp`, for a token whose `iat` is far from now.
    fileprivate init(copying claims: LTILaunchClaims, expiresAt: Date) {
        self.init(
            iss: claims.iss, sub: claims.sub, aud: claims.aud, exp: ExpirationClaim(value: expiresAt),
            iat: claims.iat, nonce: claims.nonce, azp: claims.azp, name: claims.name, email: claims.email,
            messageType: claims.messageType, version: claims.version, deploymentID: claims.deploymentID,
            targetLinkURI: claims.targetLinkURI, roles: claims.roles, context: claims.context,
            resourceLink: claims.resourceLink, custom: claims.custom, nbf: claims.nbf)
    }
}
