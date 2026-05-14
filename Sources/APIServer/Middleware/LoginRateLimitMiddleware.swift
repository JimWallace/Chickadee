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
//      the login handler via `LoginAttemptStore.isLocked` / `recordFailure`
//      / `clearFailures`, because the username is only known after the
//      request body has been decoded.
//
// Storage is in-memory (`LoginAttemptStore` actor) — the same pattern used
// by `WorkerNonceStore`.  Restart clears all state, which is fine for these
// time-bounded checks; clustered deployments would need a shared store, but
// Chickadee's deployment model is single-process today.
//
// IP extraction honours `X-Forwarded-For` only when the operator has set
// TRUST_X_FORWARDED_PROTO=true (the existing trust signal), so spoofing
// behind an untrusted proxy can't bypass the limit.

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
        let perMinute =
            Environment.get("LOGIN_RATE_LIMIT_PER_MIN")
            .flatMap(Int.init) ?? 10
        let threshold =
            Environment.get("LOGIN_LOCKOUT_THRESHOLD")
            .flatMap(Int.init) ?? 5
        let windowSeconds =
            Environment.get("LOGIN_LOCKOUT_WINDOW_SEC")
            .flatMap(TimeInterval.init) ?? 900
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
        let allowed = await request.application.loginAttemptStore.recordAndCheckIP(
            ip: ip,
            now: Date(),
            windowSeconds: 60,
            max: configuration.perMinute
        )
        if !allowed {
            request.logger.warning("Login rate limit exceeded for IP \(ip)")
            return try Self.tooManyRequestsResponse()
        }
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

// MARK: - Attempt store

/// Tracks per-IP request timestamps and per-username failure timestamps for
/// brute-force protection.  All state is in-memory and ephemeral.
actor LoginAttemptStore {
    private var ipTimestamps: [String: [Date]] = [:]
    private var userFailures: [String: [Date]] = [:]

    /// Records a request from `ip` and reports whether it should be allowed
    /// under a sliding-window cap of `max` per `windowSeconds`.  The request
    /// is counted regardless of the return value (rejected requests still
    /// count against the limit) so a misbehaving client can't game the cap
    /// by exceeding it.
    func recordAndCheckIP(
        ip: String,
        now: Date,
        windowSeconds: TimeInterval,
        max: Int
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var list = (ipTimestamps[ip] ?? []).filter { $0 > cutoff }
        list.append(now)
        ipTimestamps[ip] = list
        return list.count <= max
    }

    /// Returns true if the given username has accumulated `threshold` or
    /// more failed logins inside the trailing `windowSeconds`.
    func isLocked(
        username: String,
        now: Date,
        windowSeconds: TimeInterval,
        threshold: Int
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let list = (userFailures[username] ?? []).filter { $0 > cutoff }
        userFailures[username] = list
        return list.count >= threshold
    }

    /// Records a failed login attempt against `username`.  Failures older
    /// than `windowSeconds` are pruned at the same time.
    func recordFailure(
        username: String,
        now: Date,
        windowSeconds: TimeInterval
    ) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var list = (userFailures[username] ?? []).filter { $0 > cutoff }
        list.append(now)
        userFailures[username] = list
    }

    /// Clears all failure records for `username`.  Called after a successful
    /// login so the user isn't subsequently locked out by their own pre-
    /// success retries.
    func clearFailures(username: String) {
        userFailures[username] = nil
    }
}

// MARK: - Application storage

struct LoginAttemptStoreKey: StorageKey {
    typealias Value = LoginAttemptStore
}

struct LoginRateLimitConfigurationKey: StorageKey {
    typealias Value = LoginRateLimitConfiguration
}

extension Application {
    var loginAttemptStore: LoginAttemptStore {
        get {
            if let existing = storage[LoginAttemptStoreKey.self] { return existing }
            let created = LoginAttemptStore()
            storage[LoginAttemptStoreKey.self] = created
            return created
        }
        set { storage[LoginAttemptStoreKey.self] = newValue }
    }

    var loginRateLimitConfiguration: LoginRateLimitConfiguration {
        get { storage[LoginRateLimitConfigurationKey.self] ?? .default }
        set { storage[LoginRateLimitConfigurationKey.self] = newValue }
    }
}
