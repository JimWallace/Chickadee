// Tests/APITests/GitHub/GitHubAppJWTTests.swift
//
// The App JWT (docs/github-submissions.md slice 3): signed RS256 with the
// PKCS#1 key GitHub issues, `iss` set to the App ID, and a lifetime inside
// GitHub's ten-minute maximum.

import CryptoExtras
import Foundation
import JWT
import Testing

@testable import APIServer

@Suite struct GitHubAppJWTTests {
    @Test func signsWithAPKCS1KeyAndVerifiesWithItsPublicHalf() async throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        #expect(key.pemRepresentation.contains("BEGIN RSA PRIVATE KEY"))
        let now = Date()
        let token = try await GitHubAppJWT.sign(appID: 42, privateKeyPEM: key.pemRepresentation, now: now)

        let publicKey = try Insecure.RSA.PublicKey(pem: key.publicKey.pemRepresentation)
        let keys = await JWTKeyCollection().add(rsa: publicKey, digestAlgorithm: .sha256)
        let payload = try await keys.verify(token, as: GitHubAppJWT.self)
        #expect(payload.iss.value == "42")
        #expect(payload.iat.value <= now)
        #expect(payload.exp.value.timeIntervalSince(payload.iat.value) <= 600)
    }

    @Test func headerNamesRS256() async throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let token = try await GitHubAppJWT.sign(appID: 7, privateKeyPEM: key.pemRepresentation)
        let header = try #require(token.split(separator: ".").first)
        var base64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let json = try #require(Data(base64Encoded: base64))
        let decoded = try JSONDecoder().decode([String: String].self, from: json)
        #expect(decoded["alg"] == "RS256")
    }

    @Test func refusesAKeyThatIsNotAPEM() async {
        await #expect(throws: (any Error).self) {
            _ = try await GitHubAppJWT.sign(appID: 1, privateKeyPEM: "pem")
        }
    }
}
