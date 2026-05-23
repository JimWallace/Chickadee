// APIServer/MCP/Auth/MCPTokenAuthority.swift
//
// Signs and verifies MCP access tokens with an ES256 (P-256) key — Chickadee
// acting as its own authorization server for Phase 1.  The private key is
// persisted to disk and auto-generated on first use (like the worker secret).
// The same key collection verifies in-process; the public key is also exported
// as a JWK (RFC 9728 metadata / JWKS endpoint, step 7).

import Foundation
import JWT
import Vapor

actor MCPTokenAuthority {
    let keyID: JWKIdentifier
    let privateKeyPEM: String
    /// EC public-key parameters (base64url x/y) for JWKS export.
    let publicKeyParameters: ECDSAParameters?
    private let keys: JWTKeyCollection

    private init(
        keyID: JWKIdentifier,
        privateKeyPEM: String,
        publicKeyParameters: ECDSAParameters?,
        keys: JWTKeyCollection
    ) {
        self.keyID = keyID
        self.privateKeyPEM = privateKeyPEM
        self.publicKeyParameters = publicKeyParameters
        self.keys = keys
    }

    /// Builds an authority from a PEM-encoded ES256 private key.
    static func make(privateKeyPEM: String, keyID: String) async throws -> MCPTokenAuthority {
        let key = try ES256PrivateKey(pem: privateKeyPEM)
        let kid = JWKIdentifier(string: keyID)
        let keys = await JWTKeyCollection().add(ecdsa: key, kid: kid)
        return MCPTokenAuthority(
            keyID: kid,
            privateKeyPEM: privateKeyPEM,
            publicKeyParameters: key.publicKey.parameters,
            keys: keys
        )
    }

    /// Loads the ES256 key from `path`, generating and persisting a new one
    /// (mode 0600) if the file is absent or empty.
    static func loadOrGenerate(path: String, keyID: String) async throws -> MCPTokenAuthority {
        let pem: String
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
            !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            pem = existing
        } else {
            pem = ES256PrivateKey().pemRepresentation
            try pem.write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        return try await make(privateKeyPEM: pem, keyID: keyID)
    }

    /// Mints a signed MCP access token for `subject` carrying `scopes`.
    func mint(
        subject: String,
        scopes: Set<ContentScope>,
        issuer: String,
        audience: String,
        ttlSeconds: Int,
        now: Date = Date()
    ) async throws -> String {
        let claims = MCPAccessTokenClaims(
            sub: SubjectClaim(value: subject),
            iss: IssuerClaim(value: issuer),
            aud: AudienceClaim(value: audience),
            exp: ExpirationClaim(value: now.addingTimeInterval(TimeInterval(ttlSeconds))),
            iat: IssuedAtClaim(value: now),
            scope: scopes.map(\.rawValue).sorted().joined(separator: " ")
        )
        return try await keys.sign(claims, kid: keyID)
    }

    /// Verifies a token's signature and `exp`, returning its claims.
    func verify(_ token: String) async throws -> MCPAccessTokenClaims {
        try await keys.verify(token, as: MCPAccessTokenClaims.self)
    }
}

// MARK: - Application storage

private struct MCPTokenAuthorityKey: StorageKey {
    typealias Value = MCPTokenAuthority
}

extension Application {
    /// The MCP token authority, loaded at startup when `appConfig.mcp.enabled`.
    var mcpTokenAuthority: MCPTokenAuthority? {
        get { storage[MCPTokenAuthorityKey.self] }
        set { storage[MCPTokenAuthorityKey.self] = newValue }
    }
}
