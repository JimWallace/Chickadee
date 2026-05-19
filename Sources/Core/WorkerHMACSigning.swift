// Core/WorkerHMACSigning.swift
//
// Worker ↔ server HMAC signing and verification.  One source of truth
// for both sides — without this consolidation, server and worker each
// kept a private copy of the signature algorithm and signed-payload
// format, and a one-sided edit would silently 401 every worker
// request.
//
// Signed payload format (fields joined by newlines):
//
//     METHOD\nPATH\nBODY_SHA256\nTIMESTAMP\nNONCE
//
// Required request headers (all populated by `signedHeaders(...)`):
//
//   X-Worker-Timestamp   Unix seconds, Int64 as decimal string
//   X-Worker-Nonce       Caller-chosen unique string (default: UUID)
//   X-Worker-Body-SHA256 Lowercase hex SHA-256 of the request body
//   X-Worker-Signature   Lowercase hex HMAC-SHA256 of the signed payload
//   X-Worker-Id          Worker identifier (optional)
//
// Lives in `Core` (v0.4.180+) so both `chickadee-server`
// (`WorkerHMACAuthMiddleware`) and `chickadee-runner`
// (`WorkerRequestSigner`) call this module — algorithm drift becomes
// a compile error, not a silent auth break.

import Crypto
import Foundation

public enum WorkerHMACSigning {

    /// Header field names used by the signing scheme.  Exposed as
    /// constants so neither side has to hand-spell them.
    public enum Header {
        public static let timestamp = "X-Worker-Timestamp"
        public static let nonce = "X-Worker-Nonce"
        public static let bodyHash = "X-Worker-Body-SHA256"
        public static let signature = "X-Worker-Signature"
        public static let workerID = "X-Worker-Id"
    }

    /// The exact set of headers `signedHeaders(...)` returns and that
    /// `verify(...)` consumes.  Carries the computed body hash and
    /// signature so callers don't have to re-derive them.
    public struct SignedHeaders: Sendable {
        public let timestamp: String
        public let nonce: String
        public let bodyHash: String
        public let signature: String
        public let workerID: String?

        public init(
            timestamp: String,
            nonce: String,
            bodyHash: String,
            signature: String,
            workerID: String?
        ) {
            self.timestamp = timestamp
            self.nonce = nonce
            self.bodyHash = bodyHash
            self.signature = signature
            self.workerID = workerID
        }
    }

    /// Computes the HMAC signature and full header set for a worker
    /// request.  `timestamp` and `nonce` default to "now" and a fresh
    /// UUID; tests override them.
    public static func signedHeaders(
        method: String,
        path: String,
        body: Data,
        secret: String,
        workerID: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: String = UUID().uuidString
    ) -> SignedHeaders {
        let tsString = String(timestamp)
        let bodyHash = sha256HexDigest(body)
        let payload = signedPayload(
            method: method,
            path: path,
            bodyHash: bodyHash,
            timestamp: tsString,
            nonce: nonce
        )
        let signature = hmacSHA256Hex(message: payload, secret: secret)
        return SignedHeaders(
            timestamp: tsString,
            nonce: nonce,
            bodyHash: bodyHash,
            signature: signature,
            workerID: workerID
        )
    }

    /// Verifies the supplied HMAC headers against the request method,
    /// path, and secret.  Performs constant-time comparison on the
    /// signature.  Returns `false` on any mismatch.
    ///
    /// Note: `headers.bodyHash` is the value the client sent —
    /// verifying that it matches the *actual* body bytes is the
    /// caller's responsibility (the middleware does this separately).
    public static func verify(
        method: String,
        path: String,
        headers: SignedHeaders,
        secret: String
    ) -> Bool {
        let payload = signedPayload(
            method: method,
            path: path,
            bodyHash: headers.bodyHash.lowercased(),
            timestamp: headers.timestamp,
            nonce: headers.nonce
        )
        let expected = hmacSHA256Hex(message: payload, secret: secret)
        return constantTimeEquals(expected.lowercased(), headers.signature.lowercased())
    }

    /// The canonical "what we sign" string.  Public so tests and
    /// future tooling can assert on the exact byte layout.
    public static func signedPayload(
        method: String,
        path: String,
        bodyHash: String,
        timestamp: String,
        nonce: String
    ) -> String {
        [method.uppercased(), path, bodyHash, timestamp, nonce].joined(separator: "\n")
    }

    /// Lowercase-hex HMAC-SHA256 of `message` under `secret`.  Exposed
    /// because BrightSpace Valence signing (another HMAC-SHA256 site)
    /// also needs it — keeping one implementation reduces drift risk.
    public static func hmacSHA256Hex(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return hexEncoded(Data(mac))
    }

    /// Constant-time string equality.  Both sides must be the same
    /// length; an early return on length is a deliberate non-secret
    /// leak (the length of an HMAC signature is not sensitive).
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var result: UInt8 = 0
        for i in left.indices { result |= left[i] ^ right[i] }
        return result == 0
    }
}

/// Internal — hex-encodes raw bytes lowercase.  Used by
/// `WorkerHMACSigning.hmacSHA256Hex`; not part of the public API
/// because `sha256HexDigest` already covers the SHA-256 case.
private func hexEncoded(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
