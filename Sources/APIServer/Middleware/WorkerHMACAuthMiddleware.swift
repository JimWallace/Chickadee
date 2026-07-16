import Core
import Fluent
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
        let wasInserted = try await WorkerNonceReplayGuard.insertIfNew(
            nonceKey: nonceKey,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(now + nonceTTLSeconds)),
            on: request.db
        )
        guard wasInserted else {
            throw Abort(.unauthorized, reason: "Replay detected.")
        }
        await WorkerNonceReplayGuard.purgeExpiredIfDue(
            application: request.application, db: request.db, logger: request.logger)

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

// MARK: - Nonce replay guard (database-backed)

/// Replay protection backed by the `worker_nonces` table (#1154). The old
/// in-memory actor was per-process: a signed request captured on one
/// instance could be replayed against another within the TTL window. The
/// PRIMARY KEY insert makes first-seen atomic across every process sharing
/// the database, and — as a free improvement — replaces the actor's
/// O(all nonces) dictionary rebuild on every worker request with a
/// throttled bulk DELETE.
enum WorkerNonceReplayGuard {
    /// How often (at most) a request triggers the expired-row purge.
    static let purgeInterval: TimeInterval = 60

    /// Atomically records first use of `nonceKey`. Returns false when the
    /// key was already consumed (replay). A unique-constraint failure is
    /// detected by re-fetching rather than by string-matching driver errors —
    /// the same recover-by-re-fetch idiom as `AssignmentSeedStore`. Nonces
    /// are random per request, so colliding with an expired-but-unpurged row
    /// only happens when a client actually reuses a nonce — which is exactly
    /// the thing to reject.
    static func insertIfNew(
        nonceKey: String, expiresAt: Date, on db: Database
    ) async throws -> Bool {
        let row = WorkerNonce(nonceKey: nonceKey, expiresAt: expiresAt)
        do {
            try await row.create(on: db)
            return true
        } catch {
            if try await WorkerNonce.find(nonceKey, on: db) != nil {
                return false
            }
            throw error
        }
    }

    /// Deletes expired nonce rows, at most once per `purgeInterval` per
    /// process. Best-effort: a failed purge only delays cleanup.
    static func purgeExpiredIfDue(application: Application, db: Database, logger: Logger) async {
        let due = await application.workerNoncePurgeThrottle.shouldRun(
            now: Date(), interval: purgeInterval)
        guard due else { return }
        do {
            try await WorkerNonce.query(on: db)
                .filter(\.$expiresAt <= Date())
                .delete()
        } catch {
            logger.warning("worker_nonce_purge_failed: \(String(describing: error))")
        }
    }
}

/// Rate-limits a recurring maintenance action to once per interval per
/// process (same shape as `DiagnosticsMaintenanceStore`).
actor PurgeThrottle {
    private var lastRunAt: Date?

    func shouldRun(now: Date, interval: TimeInterval) -> Bool {
        if let lastRunAt, now.timeIntervalSince(lastRunAt) < interval {
            return false
        }
        lastRunAt = now
        return true
    }
}

struct WorkerNoncePurgeThrottleKey: StorageKey {
    typealias Value = PurgeThrottle
}

extension Application {
    var workerNoncePurgeThrottle: PurgeThrottle {
        get {
            if let existing = storage[WorkerNoncePurgeThrottleKey.self] { return existing }
            let created = PurgeThrottle()
            storage[WorkerNoncePurgeThrottleKey.self] = created
            return created
        }
        set { storage[WorkerNoncePurgeThrottleKey.self] = newValue }
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
