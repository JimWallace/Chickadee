// APIServer/LTI/LTIToolKeyAuthority.swift
//
// The LTI 1.3 tool key (docs/lti-1-3.md "The tool key"). The IMS Security
// Framework requires RS256, and D2L refuses ES256, so this is a separate RSA
// key rather than the MCP authority's ES256 key. The platform verifies the
// tool's signed messages (deep-linking responses, AGS/NRPS client assertions)
// against the public half, which `GET /lti/jwks` publishes.

import Crypto
import CryptoExtras
import Foundation
import JWT

actor LTIToolKeyAuthority {
    /// RFC 7638 thumbprint of the public key, so a rotated key gets a new
    /// `kid` without anyone choosing one.
    nonisolated let keyID: JWKIdentifier
    private let modulus: String
    private let exponent: String
    private let keys: JWTKeyCollection

    private init(keyID: JWKIdentifier, modulus: String, exponent: String, keys: JWTKeyCollection) {
        self.keyID = keyID
        self.modulus = modulus
        self.exponent = exponent
        self.keys = keys
    }

    /// Builds an authority from a PEM-encoded RSA private key (2048 bits or more).
    static func make(privateKeyPEM: String) async throws -> LTIToolKeyAuthority {
        let key = try Insecure.RSA.PrivateKey(pem: privateKeyPEM)
        let primitives = try key.publicKey.getKeyPrimitives()
        let modulus = primitives.modulus.base64URLEncodedString()
        let exponent = primitives.publicExponent.base64URLEncodedString()
        let kid = JWKIdentifier(string: thumbprint(modulus: modulus, exponent: exponent))
        let keys = await JWTKeyCollection().add(rsa: key, digestAlgorithm: .sha256, kid: kid)
        return LTIToolKeyAuthority(keyID: kid, modulus: modulus, exponent: exponent, keys: keys)
    }

    /// Loads the key from `path`, or generates a 2048-bit key and writes it
    /// there (mode 0600) when the file is absent or empty.
    static func loadOrGenerate(path: String) async throws -> LTIToolKeyAuthority {
        let pem = try SecretFile.loadOrCreateText(path: path) {
            try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
        }
        return try await make(privateKeyPEM: pem)
    }

    /// Signs `payload` as an RS256 JWT carrying this key's `kid`.
    func sign(_ payload: some JWTPayload) async throws -> String {
        try await keys.sign(payload, kid: keyID)
    }

    /// The public key as a JWK (RFC 7517) for the JWKS endpoint.
    func publicJWK() -> [String: String] {
        [
            "kty": "RSA",
            "use": "sig",
            "alg": "RS256",
            "kid": keyID.string,
            "n": modulus,
            "e": exponent,
        ]
    }

    /// RFC 7638 JWK thumbprint: SHA-256 over the required members in
    /// lexicographic order with no whitespace, base64url-encoded.
    static func thumbprint(modulus: String, exponent: String) -> String {
        let canonical = #"{"e":"\#(exponent)","kty":"RSA","n":"\#(modulus)"}"#
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncodedString()
    }
}
