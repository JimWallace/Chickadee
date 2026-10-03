// APIServer/GitHub/GitHubAppJWT.swift
//
// The short-lived JWT a GitHub App signs with its private key to act as the
// App (docs/github-submissions.md slice 3). The server uses it to get an
// installation token, and to read what the App and its installations may do
// (#1776). GitHub requires RS256, `iss` set to the App ID, and a lifetime of
// ten minutes or less.

import Crypto
import Foundation
import JWT

struct GitHubAppJWT: JWTPayload, Equatable {
    /// Well inside GitHub's ten-minute maximum.
    static let lifetime: TimeInterval = 540
    /// GitHub's advice: back-date `iat` a little to allow for clock drift.
    static let clockSkew: TimeInterval = 60

    let iss: IssuerClaim
    let iat: IssuedAtClaim
    let exp: ExpirationClaim

    init(appID: Int, now: Date) {
        iss = IssuerClaim(value: String(appID))
        iat = IssuedAtClaim(value: now.addingTimeInterval(-Self.clockSkew))
        exp = ExpirationClaim(value: now.addingTimeInterval(Self.lifetime))
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    /// Signs a JWT for `appID` with the App's PEM private key. GitHub issues
    /// the key in PKCS#1 form; PKCS#8 is accepted too.
    static func sign(appID: Int, privateKeyPEM: String, now: Date = Date()) async throws -> String {
        let key = try Insecure.RSA.PrivateKey(pem: privateKeyPEM)
        let keys = await JWTKeyCollection().add(rsa: key, digestAlgorithm: .sha256)
        return try await keys.sign(GitHubAppJWT(appID: appID, now: now))
    }
}
