// APIServer/Middleware/LoginRateLimitMiddleware.swift
//
// Brute-force protection for /login and /register.
//
// Two tiers:
//
//   1. Per-IP rate limit — at most `perMinute` POSTs to login/register from
//      a single remote address inside a 60-second sliding window.  Returns
//      429 with Retry-After when exceeded.  Enforced by this middleware so
//      no body parsing is required and unknown clients can't reach the
//      handler at all.
//
//   2. Per-username lockout — `threshold` failed login attempts against the
//      same username inside a `windowSeconds` sliding window puts the
//      account in a soft lockout state.  Subsequent attempts return 423
//      Locked until the window passes or a successful login (e.g. by an
//      admin after manual reset) clears the failure record.  Enforced by
//      the login handler via `LoginAttemptService.isLocked` / `recordFailure`
//      / `clearFailures`, because the username is only known after the
//      request body has been decoded.
//
// Storage is the `login_attempts` table (#1154).  The counts must be shared
// across server processes: with the old in-memory actor, N instances behind
// a load balancer meant N× the configured per-IP rate and lockouts that only
// counted the failures that happened to land on the same instance.  Login
// traffic is low-frequency, so the two or three indexed queries per POST are
// negligible.
//
// IP extraction honours `X-Forwarded-For` only when the operator has set
// TRUST_X_FORWARDED_PROTO=true (the existing trust signal), so spoofing
// behind an untrusted proxy can't bypass the limit.

import Fluent
import Foundation
import Vapor

struct LoginRateLimitConfiguration: Sendable {
    let enabled: Bool
    let perMinute: Int
    let lockoutThreshold: Int
    let lockoutWindowSeconds: TimeInterval
    let trustForwardedFor: Bool

    static let `default` = LoginRateLimitConfiguration(
        enabled: true,
        perMinute: 10,
        lockoutThreshold: 5,
        lockoutWindowSeconds: 900,
        trustForwardedFor: true
    )

    static func fromEnvironment(trustForwardedFor: Bool) -> Self {
        let perMinute = environmentInt("LOGIN_RATE_LIMIT_PER_MIN") ?? 10
        let threshold = environmentInt("LOGIN_LOCKOUT_THRESHOLD") ?? 5
        let windowSeconds = environmentDouble("LOGIN_LOCKOUT_WINDOW_SEC") ?? 900
        let enabled = environmentBool("LOGIN_RATE_LIMIT_ENABLED") ?? true
        return LoginRateLimitConfiguration(
            enabled: enabled,
            perMinute: max(1, perMinute),
            lockoutThreshold: max(1, threshold),
            lockoutWindowSeconds: max(60, windowSeconds),
            trustForwardedFor: trustForwardedFor
        )
    }
}

struct LoginRateLimitMiddleware: AsyncMiddleware {
    let configuration: LoginRateLimitConfiguration

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard configuration.enabled, request.method == .POST else {
            return try await next.respond(to: request)
        }
        let path = request.url.path
        guard path == "/login" || path == "/register" else {
            return try await next.respond(to: request)
        }

        let ip = clientIPAddress(
            from: request,
            trustForwardedFor: configuration.trustForwardedFor
        )
        let allowed = try await LoginAttemptService.recordAndCheckIP(
            ip: ip,
            now: Date(),
            windowSeconds: 60,
            max: configuration.perMinute,
            on: request.db
        )
        if !allowed {
            // IP in metadata only — an IP is personal information, and message
            // text reaches the admin query_logs buffer unredacted (audit F-1).
            request.logger.warning(
                "Login rate limit exceeded", metadata: ["ip": .string(ip)])
            return try Self.tooManyRequestsResponse()
        }
        await LoginAttemptService.purgeStaleIfDue(
            application: request.application,
            db: request.db,
            lockoutWindowSeconds: configuration.lockoutWindowSeconds,
            logger: request.logger
        )
        return try await next.respond(to: request)
    }

    private static func tooManyRequestsResponse() throws -> Response {
        let response = Response(status: .tooManyRequests)
        response.headers.replaceOrAdd(name: "Retry-After", value: "60")
        try response.content.encode(["error": "rate_limited"])
        return response
    }
}

// MARK: - Helpers used by AuthRoutes.login

/// Extracts a client IP address suitable for rate-limit keying.  Uses
/// `X-Forwarded-For` only when explicitly trusted; otherwise falls back to
/// the socket peer address.  Returns "unknown" when neither is available
/// (typically only in unit tests).
func clientIPAddress(from request: Request, trustForwardedFor: Bool) -> String {
    if trustForwardedFor,
        let xff = request.headers.first(name: "X-Forwarded-For")
    {
        if let first = xff.split(separator: ",").first {
            let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    if let ip = request.remoteAddress?.ipAddress, !ip.isEmpty {
        return ip
    }
    return "unknown"
}

// MARK: - Attempt service (database-backed)

/// Tracks per-IP request events and per-username failure events for
/// brute-force protection, in the `login_attempts` table so the sliding
/// windows are shared across server processes (#1154). Every query is
/// covered by the (scope, attempt_key, occurred_at) index; per-key rows are
/// pruned on each write so a key's row count is bounded by its own window.
enum LoginAttemptService {
    /// How often (at most) a request triggers the global stale-row sweep.
    static let purgeInterval: TimeInterval = 600

    /// Records a request from `ip` and reports whether it should be allowed
    /// under a sliding-window cap of `max` per `windowSeconds`.  The request
    /// is counted regardless of the return value (rejected requests still
    /// count against the limit) so a misbehaving client can't game the cap
    /// by exceeding it.
    static func recordAndCheckIP(
        ip: String,
        now: Date,
        windowSeconds: TimeInterval,
        max: Int,
        on db: Database
    ) async throws -> Bool {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.ip)
            .filter(\.$attemptKey == ip)
            .filter(\.$occurredAt <= cutoff)
            .delete()
        try await LoginAttempt(scope: LoginAttempt.Scope.ip, attemptKey: ip, occurredAt: now)
            .create(on: db)
        let count = try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.ip)
            .filter(\.$attemptKey == ip)
            .filter(\.$occurredAt > cutoff)
            .count()
        return count <= max
    }

    /// Returns true if the given username has accumulated `threshold` or
    /// more failed logins inside the trailing `windowSeconds`.
    static func isLocked(
        username: String,
        now: Date,
        windowSeconds: TimeInterval,
        threshold: Int,
        on db: Database
    ) async throws -> Bool {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let count = try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.userFailure)
            .filter(\.$attemptKey == username)
            .filter(\.$occurredAt > cutoff)
            .count()
        return count >= threshold
    }

    /// Records a failed login attempt against `username`.  Failures older
    /// than `windowSeconds` are pruned at the same time.
    static func recordFailure(
        username: String,
        now: Date,
        windowSeconds: TimeInterval,
        on db: Database
    ) async throws {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.userFailure)
            .filter(\.$attemptKey == username)
            .filter(\.$occurredAt <= cutoff)
            .delete()
        try await LoginAttempt(
            scope: LoginAttempt.Scope.userFailure, attemptKey: username, occurredAt: now
        ).create(on: db)
    }

    /// Clears all failure records for `username`.  Called after a successful
    /// login so the user isn't subsequently locked out by their own pre-
    /// success retries.
    static func clearFailures(username: String, on db: Database) async throws {
        try await LoginAttempt.query(on: db)
            .filter(\.$scope == LoginAttempt.Scope.userFailure)
            .filter(\.$attemptKey == username)
            .delete()
    }

    /// Sweeps rows old enough to be outside every window (keys that never
    /// came back and so were never pruned on-write). Throttled per process;
    /// best-effort.
    static func purgeStaleIfDue(
        application: Application,
        db: Database,
        lockoutWindowSeconds: TimeInterval,
        logger: Logger
    ) async {
        let due = await application.loginAttemptPurgeThrottle.shouldRun(
            now: Date(), interval: purgeInterval)
        guard due else { return }
        let horizon = Date().addingTimeInterval(-Swift.max(lockoutWindowSeconds, 3600))
        do {
            try await LoginAttempt.query(on: db)
                .filter(\.$occurredAt <= horizon)
                .delete()
        } catch {
            logger.warning("login_attempt_purge_failed: \(String(describing: error))")
        }
    }
}

// MARK: - Application storage

struct LoginRateLimitConfigurationKey: StorageKey {
    typealias Value = LoginRateLimitConfiguration
}

struct LoginAttemptPurgeThrottleKey: StorageKey {
    typealias Value = PurgeThrottle
}

extension Application {
    var loginRateLimitConfiguration: LoginRateLimitConfiguration {
        get { storage[LoginRateLimitConfigurationKey.self] ?? .default }
        set { storage[LoginRateLimitConfigurationKey.self] = newValue }
    }

    var loginAttemptPurgeThrottle: PurgeThrottle {
        get {
            if let existing = storage[LoginAttemptPurgeThrottleKey.self] { return existing }
            let created = PurgeThrottle()
            storage[LoginAttemptPurgeThrottleKey.self] = created
            return created
        }
        set { storage[LoginAttemptPurgeThrottleKey.self] = newValue }
    }
}
