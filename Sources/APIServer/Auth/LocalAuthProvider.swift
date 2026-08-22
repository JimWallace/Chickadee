// APIServer/Auth/LocalAuthProvider.swift
//
// Username/password credential verification against the local user table —
// the whole of AUTH_MODE=local, and the local half of AUTH_MODE=dual.  The
// SSO path is not username/password-shaped and never comes through here; it
// lives in SSOAuthRoutes.
//
// A plain stateless struct, not a strategy protocol: there is exactly one
// way to verify a local password, and the protocol seam that used to wrap
// this went unused by the SSO flow and the tests alike (#449).

import Fluent
import Vapor

/// BCrypt-backed credential verification against the local user table.
///
/// Returns the matching `APIUser` on success, or `nil` for invalid
/// credentials.  Safe to call from concurrent request handlers.
struct LocalAuthProvider {
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
