import Crypto
import Foundation
import Vapor

/// Authenticates internal worker requests using HMAC signatures.
///
/// Not wired into routes yet. Intended usage later:
///   let workerAuth = WorkerHMACAuthMiddleware(configuration: .fromEnvironment(app.environment))
///   let worker = app.grouped("internal", "worker").grouped(workerAuth)
///   worker.post("heartbeat") { ... }
struct WorkerHMACAuthMiddleware: AsyncMiddleware {
    struct Configuration {
        let sharedSecret: String
        let maxClockSkewSeconds: Int64
        let nonceTTLSeconds: Int64
        let requiredWorkerID: String?

        static func fromEnvironment(_ env: Environment) -> Self {
            // Expected env vars:
            // - WORKER_SHARED_SECRET (required)
            // - WORKER_MAX_CLOCK_SKEW_SECONDS (optional, default 60)
            // - WORKER_NONCE_TTL_SECONDS (optional, default 300)
            // - WORKER_REQUIRED_ID (optional)
            _ = env // placeholder in case you want env-specific defaults later.
            return Self(
                sharedSecret: Environment.get("WORKER_SHARED_SECRET") ?? "",
                maxClockSkewSeconds: Int64(Environment.get("WORKER_MAX_CLOCK_SKEW_SECONDS") ?? "60") ?? 60,
                nonceTTLSeconds: Int64(Environment.get("WORKER_NONCE_TTL_SECONDS") ?? "300") ?? 300,
                requiredWorkerID: Environment.get("WORKER_REQUIRED_ID")
            )
        }
    }

    private let configuration: Configuration
    private let nonceStore: WorkerNonceStore

    init(configuration: Configuration, nonceStore: WorkerNonceStore = .init()) {
        self.configuration = configuration
        self.nonceStore = nonceStore
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard !configuration.sharedSecret.isEmpty else {
            request.logger.warning("Worker HMAC auth is enabled but WORKER_SHARED_SECRET is empty.")
            throw Abort(.unauthorized, reason: "Worker auth is not configured.")
        }

        let timestampHeader = try request.requireHeader("X-Worker-Timestamp")
        let nonce = try request.requireHeader("X-Worker-Nonce")
        let signature = try request.requireHeader("X-Worker-Signature")
        let workerID = request.headers.first(name: "X-Worker-Id")

        if let required = configuration.requiredWorkerID, workerID != required {
            throw Abort(.unauthorized, reason: "Invalid worker identity.")
        }

        guard let timestamp = Int64(timestampHeader) else {
            throw Abort(.unauthorized, reason: "Invalid worker timestamp.")
        }

        let now = Int64(Date().timeIntervalSince1970)
        let drift = abs(now - timestamp)
        guard drift <= configuration.maxClockSkewSeconds else {
            throw Abort(.unauthorized, reason: "Worker request timestamp is outside the accepted window.")
        }

        let nonceKey = (workerID ?? "_anonymous") + ":" + nonce
        let wasInserted = await nonceStore.insertIfNew(nonceKey, now: now, ttlSeconds: configuration.nonceTTLSeconds)
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

        let expectedSignature = hmacSHA256Hex(message: signedPayload, secret: configuration.sharedSecret)
        guard constantTimeEquals(expectedSignature.lowercased(), signature.lowercased()) else {
            throw Abort(.unauthorized, reason: "Invalid worker signature.")
        }

        return try await next.respond(to: request)
    }
}

actor WorkerNonceStore {
    private var seen: [String: Int64] = [:]

    func insertIfNew(_ nonce: String, now: Int64, ttlSeconds: Int64) -> Bool {
        purgeExpired(now: now)
        if seen[nonce] != nil {
            return false
        }
        seen[nonce] = now + ttlSeconds
        return true
    }

    private func purgeExpired(now: Int64) {
        seen = seen.filter { $0.value > now }
    }
}

private extension Request {
    func requireHeader(_ name: String) throws -> String {
        guard let value = headers.first(name: name), !value.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing worker auth header: \(name)")
        }
        return value
    }
}

private func bodyBytes(_ request: Request) -> [UInt8] {
    guard var data = request.body.data else {
        return []
    }
    return data.readBytes(length: data.readableBytes) ?? []
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    let digest = SHA256.hash(data: Data(bytes))
    return digest.hexString
}

private func hmacSHA256Hex(message: String, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return Data(mac).hexEncodedString()
}

private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var result: UInt8 = 0
    for i in left.indices {
        result |= left[i] ^ right[i]
    }
    return result == 0
}

private extension Digest {
    var hexString: String {
        Data(self).hexEncodedString()
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
