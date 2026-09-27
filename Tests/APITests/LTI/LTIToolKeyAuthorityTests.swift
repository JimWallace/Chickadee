// Tests/APITests/LTI/LTIToolKeyAuthorityTests.swift
//
// The LTI tool key (docs/lti-1-3.md "The tool key"): RS256 because the IMS
// Security Framework and D2L require it, persisted once with mode 0600, and
// identified by an RFC 7638 thumbprint so the `kid` follows the key.

import Foundation
import JWT
import Testing

@testable import APIServer

@Suite(.serialized) final class LTIToolKeyAuthorityTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var keyPath: String { directory.appendingPathComponent(".lti-tool-key").path }

    struct TestPayload: JWTPayload, Equatable {
        let sub: SubjectClaim
        let exp: ExpirationClaim

        func verify(using _: some JWTAlgorithm) async throws {
            try exp.verifyNotExpired()
        }
    }

    /// RFC 7638 §3.1's worked example, so the thumbprint is checked against
    /// the specification rather than against itself.
    @Test func thumbprintMatchesTheRFC7638Example() {
        let modulus =
            "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECP"
            + "ebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2Qvz"
            + "qY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0"
            + "fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"
        #expect(
            LTIToolKeyAuthority.thumbprint(modulus: modulus, exponent: "AQAB")
                == "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs")
    }

    @Test func generatesAnOwnerOnlyKeyFileOnFirstUse() async throws {
        #expect(!FileManager.default.fileExists(atPath: keyPath))
        _ = try await LTIToolKeyAuthority.loadOrGenerate(path: keyPath)

        let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        #expect(pem.contains("PRIVATE KEY"))
    }

    @Test func reloadingTheFileKeepsTheSameKeyID() async throws {
        let first = try await LTIToolKeyAuthority.loadOrGenerate(path: keyPath)
        let second = try await LTIToolKeyAuthority.loadOrGenerate(path: keyPath)
        #expect(first.keyID == second.keyID)
    }

    @Test func publicJWKIsAnRS256SigningKeyNamedByItsThumbprint() async throws {
        let authority = try await LTIToolKeyAuthority.loadOrGenerate(path: keyPath)
        let jwk = await authority.publicJWK()
        #expect(jwk["kty"] == "RSA")
        #expect(jwk["alg"] == "RS256")
        #expect(jwk["use"] == "sig")
        #expect(jwk["e"] == "AQAB")
        let modulus = try #require(jwk["n"])
        #expect(!modulus.contains("=") && !modulus.contains("+") && !modulus.contains("/"))
        #expect(jwk["kid"] == LTIToolKeyAuthority.thumbprint(modulus: modulus, exponent: "AQAB"))
        #expect(jwk["d"] == nil, "the JWKS must never carry the private exponent")
    }

    /// A platform verifies tool messages with the published JWK alone, so the
    /// test does too: a key set built only from `publicJWK()` must accept a
    /// token the authority signed.
    @Test func publishedJWKVerifiesATokenTheAuthoritySigned() async throws {
        let authority = try await LTIToolKeyAuthority.loadOrGenerate(path: keyPath)
        let payload = TestPayload(
            sub: SubjectClaim(value: "tool"),
            // Whole seconds: a JWT carries `exp` as an integer, so a fractional
            // date would not survive the round trip.
            exp: ExpirationClaim(value: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 300).rounded())))
        let token = try await authority.sign(payload)

        let jwksJSON = try JSONEncoder().encode(["keys": [await authority.publicJWK()]])
        let jwksString = try #require(String(bytes: jwksJSON, encoding: .utf8))
        let platformKeys = try await JWTKeyCollection().add(jwksJSON: jwksString)
        #expect(try await platformKeys.verify(token, as: TestPayload.self) == payload)

        let header = try #require(token.split(separator: ".").first)
        let headerJSON = try #require(Data(base64URLEncoded: String(header)))
        let decoded = try JSONDecoder().decode([String: String].self, from: headerJSON)
        #expect(decoded["alg"] == "RS256")
        #expect(decoded["kid"] == authority.keyID.string)
    }

    @Test func concurrentFirstCallersShareOneKey() async throws {
        let provider = LTIToolKeyProvider()
        let path = keyPath
        async let first = provider.authority(path: path)
        async let second = provider.authority(path: path)
        let (a, b) = try await (first, second)
        #expect(a.keyID == b.keyID)
        let onDisk = try await LTIToolKeyAuthority.loadOrGenerate(path: path)
        #expect(onDisk.keyID == a.keyID)
    }
}

extension Data {
    fileprivate init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
