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

import Vapor
import Fluent

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
        guard let user = try await APIUser.query(on: req.db)
            .filter(\.$username == username)
            .first()
        else {
            return nil
        }
        let verified = try await req.password.async.verify(password, created: user.passwordHash)
        return verified ? user : nil
    }
}

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
