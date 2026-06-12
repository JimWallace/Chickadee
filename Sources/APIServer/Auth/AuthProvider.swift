// APIServer/Auth/AuthProvider.swift
//
// Pluggable credential-verification strategy.
//
// AUTH_MODE=local  → LocalAuthProvider (BCrypt, default)
// AUTH_MODE=sso    → future OIDC provider
// AUTH_MODE=dual   → both; local is tried first
//
// Callers use req.application.authProvider.authenticate(…) instead of
// talking to the database directly. This keeps auth logic out of route
// handlers and makes testing without a real SSO server straightforward.

import Fluent
import Vapor

// MARK: - Protocol

/// Returns the matching `APIUser` on success, or `nil` for invalid credentials.
/// Implementations must be safe to call from concurrent request handlers.
protocol AuthProvider: Sendable {
    func authenticate(username: String, password: String, on req: Request) async throws -> APIUser?
}

// MARK: - LocalAuthProvider

/// BCrypt-backed credential verification against the local user table.
struct LocalAuthProvider: AuthProvider {
    func authenticate(username: String, password: String, on req: Request) async throws -> APIUser? {
        let user = try await APIUser.query(on: req.db)
            .filter(\.$username == username)
            .first()
        // Always run a bcrypt verify — even on user-not-found, against a
        // cached dummy hash — so the wall-clock time of "no such user" and
        // "user found, password wrong" are indistinguishable to a remote
        // observer.  Skipping the verify on miss is a textbook account-
        // enumeration timing leak (~150ms bcrypt cost is easily measured).
        let hash: String
        if let user {
            hash = user.passwordHash
        } else {
            hash = try await timingEqualizerHashCache.hash(using: req.password.async)
        }
        let verified = try await req.password.async.verify(password, created: hash)
        return verified ? user : nil
    }
}

/// One-shot cache of a bcrypt hash used to equalize verify timing on the
/// user-not-found path.  Computed lazily on the first miss via the same
/// `AsyncPasswordHasher` the real verify uses, so the cost factor (and
/// therefore verify time) is identical to a real account.
private actor TimingEqualizerHashCache {
    private var cached: String?

    func hash(using hasher: AsyncPasswordHasher) async throws -> String {
        if let cached { return cached }
        let value = try await hasher.hash("chickadee-login-timing-equalizer-not-a-real-password")
        cached = value
        return value
    }
}

private let timingEqualizerHashCache = TimingEqualizerHashCache()

// MARK: - Application storage

private struct AuthProviderKey: StorageKey {
    typealias Value = any AuthProvider
}

extension Application {
    /// The active auth provider. Defaults to `LocalAuthProvider` if not explicitly set.
    var authProvider: any AuthProvider {
        get { storage[AuthProviderKey.self] ?? LocalAuthProvider() }
        set { storage[AuthProviderKey.self] = newValue }
    }
}
