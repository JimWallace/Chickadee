import Core
import Foundation
import Vapor

/// Authenticates internal worker requests using per-request HMAC
/// signatures.  Algorithm and signed-payload format live in
/// `Core/WorkerHMACSigning.swift` so this middleware and
/// `chickadee-runner`'s `WorkerRequestSigner` cannot drift.
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

        let timestampHeader = try request.requireWorkerHeader(WorkerHMACSigning.Header.timestamp)
        let nonce = try request.requireWorkerHeader(WorkerHMACSigning.Header.nonce)
        let bodyHashHeader = try request.requireWorkerHeader(WorkerHMACSigning.Header.bodyHash)
        let signature = try request.requireWorkerHeader(WorkerHMACSigning.Header.signature)
        let workerID = request.headers.first(name: WorkerHMACSigning.Header.workerID)

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

        let headers = WorkerHMACSigning.SignedHeaders(
            timestamp: timestampHeader,
            nonce: nonce,
            bodyHash: bodyHashHeader,
            signature: signature,
            workerID: workerID
        )
        guard
            WorkerHMACSigning.verify(
                method: request.method.rawValue,
                path: request.url.path,
                headers: headers,
                secret: sharedSecret
            )
        else {
            throw Abort(.unauthorized, reason: "Invalid worker signature.")
        }

        let response = try await next.respond(to: request)

        // Update last-seen AFTER the handler responds so that a 409 conflict
        // response does NOT refresh lastSeen.  If we updated before the handler,
        // the conflict TTL would be reset on every poll attempt and would never
        // expire, permanently locking out a runner whose container hostname
        // changed on restart (e.g. docker compose down/up with a fixed
        // RUNNER_WORKER_ID).  Skipping the touch on 409 lets lastSeen go stale
        // naturally so the TTL expires and the runner can re-register with its
        // new hostname and updated version.
        //
        // Pass hostname: "" — the middleware has no access to the request body,
        // so we preserve whatever hostname the handler already wrote rather than
        // clobbering it with an empty string.
        if let workerID, !workerID.isEmpty, response.status != .conflict {
            await request.application.workerActivityStore.markActive(workerID: workerID, hostname: "")
        }

        return response
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

// `hmacSHA256Hex` / `constantTimeEquals` / hex-encoding moved to
// `Core/WorkerHMACSigning.swift` in v0.4.180 so server and worker
// can't drift.
