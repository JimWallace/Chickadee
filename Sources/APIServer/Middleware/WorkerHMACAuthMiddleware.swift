import Crypto
import Foundation
import Vapor

/// Authenticates internal worker requests using per-request HMAC signatures.
///
/// Signed payload format (fields joined by newlines):
///   METHOD\nPATH\nBODY_SHA256\nTIMESTAMP\nNONCE
///
/// Required request headers:
///   X-Worker-Timestamp  — Unix timestamp (seconds, Int64)
///   X-Worker-Nonce      — UUID or other unique string
///   X-Worker-Signature  — HMAC-SHA256 hex of the signed payload
///   X-Worker-Id         — Worker identifier (optional; logged and used for activity tracking)
///
/// The shared secret is read from the application's WorkerSecretStore on every
/// request so that admin-panel secret rotations take effect without a restart.
struct WorkerHMACAuthMiddleware: AsyncMiddleware {
    let maxClockSkewSeconds: Int64
    let nonceTTLSeconds: Int64

    init(maxClockSkewSeconds: Int64 = 60, nonceTTLSeconds: Int64 = 300) {
        self.maxClockSkewSeconds = maxClockSkewSeconds
        self.nonceTTLSeconds = nonceTTLSeconds
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let sharedSecret = (await request.application.workerSecretStore.effectiveSecret() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sharedSecret.isEmpty else {
            request.logger.warning("Worker HMAC auth: RUNNER_SHARED_SECRET is not configured.")
            throw Abort(.unauthorized, reason: "Worker auth is not configured.")
        }

        let timestampHeader = try request.requireWorkerHeader("X-Worker-Timestamp")
        let nonce           = try request.requireWorkerHeader("X-Worker-Nonce")
        let signature       = try request.requireWorkerHeader("X-Worker-Signature")
        let workerID        = request.headers.first(name: "X-Worker-Id")

        guard let timestamp = Int64(timestampHeader) else {
            throw Abort(.unauthorized, reason: "Invalid worker timestamp.")
        }

        let now = Int64(Date().timeIntervalSince1970)
        guard abs(now - timestamp) <= maxClockSkewSeconds else {
            throw Abort(.unauthorized, reason: "Worker request timestamp is outside the accepted window.")
        }

        let nonceKey = (workerID ?? "_anonymous") + ":" + nonce
        let wasInserted = await request.application.workerNonceStore
            .insertIfNew(nonceKey, now: now, ttlSeconds: nonceTTLSeconds)
        guard wasInserted else {
            throw Abort(.unauthorized, reason: "Replay detected.")
        }

        let bodyHash = sha256Hex(bodyBytes(request))
        let signedPayload = [
            request.method.rawValue.uppercased(),
            request.url.path,
            bodyHash,
            timestampHeader,
            nonce
        ].joined(separator: "\n")

        let expectedSignature = hmacSHA256Hex(message: signedPayload, secret: sharedSecret)
        guard constantTimeEquals(expectedSignature.lowercased(), signature.lowercased()) else {
            throw Abort(.unauthorized, reason: "Invalid worker signature.")
        }

        if let workerID, !workerID.isEmpty {
            await request.application.workerActivityStore.markActive(workerID: workerID)
        }

        return try await next.respond(to: request)
    }
}

// MARK: - Application storage for the nonce store

struct WorkerNonceStoreKey: StorageKey {
    typealias Value = WorkerNonceStore
}

extension Application {
    var workerNonceStore: WorkerNonceStore {
        get {
            if let existing = storage[WorkerNonceStoreKey.self] {
                return existing
            }
            let created = WorkerNonceStore()
            storage[WorkerNonceStoreKey.self] = created
            return created
        }
        set { storage[WorkerNonceStoreKey.self] = newValue }
    }
}

// MARK: - Nonce store (replay protection)

actor WorkerNonceStore {
    private var seen: [String: Int64] = [:]

    func insertIfNew(_ nonce: String, now: Int64, ttlSeconds: Int64) -> Bool {
        purgeExpired(now: now)
        if seen[nonce] != nil { return false }
        seen[nonce] = now + ttlSeconds
        return true
    }

    private func purgeExpired(now: Int64) {
        seen = seen.filter { $0.value > now }
    }
}

// MARK: - Private helpers

private extension Request {
    func requireWorkerHeader(_ name: String) throws -> String {
        guard let value = headers.first(name: name), !value.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing worker auth header: \(name)")
        }
        return value
    }
}

private func bodyBytes(_ request: Request) -> [UInt8] {
    guard var data = request.body.data else { return [] }
    return data.readBytes(length: data.readableBytes) ?? []
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    Data(SHA256.hash(data: Data(bytes))).hexEncodedString()
}

private func hmacSHA256Hex(message: String, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return Data(mac).hexEncodedString()
}

private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8), right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var result: UInt8 = 0
    for i in left.indices { result |= left[i] ^ right[i] }
    return result == 0
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
