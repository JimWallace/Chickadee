// APIServer/GitHub/GitHubInstallationTokenCache.swift
//
// Installation tokens live for one hour. The submit page makes several GitHub
// calls per visit, so the token is kept until shortly before it expires
// instead of getting a new one for each request (docs/github-submissions.md
// "Operations"). Keyed by the GitHub account ID of the installation, which is
// what the ownership check compares against. Memory only: a restart costs one
// extra token request.

import Foundation
import Vapor

actor GitHubInstallationTokenCache {
    /// A token this close to expiry is not used again.
    static let margin: TimeInterval = 300

    private var tokens: [Int64: GitHubInstallationToken] = [:]

    func token(forAccount accountID: Int64, now: Date = Date()) -> String? {
        guard let cached = tokens[accountID] else { return nil }
        guard cached.expiresAt.timeIntervalSince(now) > Self.margin else {
            tokens[accountID] = nil
            return nil
        }
        return cached.token
    }

    func store(_ token: GitHubInstallationToken, forAccount accountID: Int64) {
        tokens[accountID] = token
    }

    func remove(account accountID: Int64) {
        tokens[accountID] = nil
    }

    /// Drops every token. The tokens belong to the registered App, so a
    /// removed registration must not keep serving them for the rest of
    /// their hour to the App registered after it (#2209).
    func removeAll() {
        tokens.removeAll()
    }

    /// True when no token is cached, for tests.
    var isEmpty: Bool { tokens.isEmpty }
}

struct GitHubInstallationTokenCacheKey: StorageKey {
    typealias Value = GitHubInstallationTokenCache
}

extension Application {
    /// Seeded at startup (`AppDirectories`), because `Application.storage`
    /// writes are not synchronized; the lazy branch serves an app built
    /// without that step, such as a test app.
    var githubInstallationTokens: GitHubInstallationTokenCache {
        if let existing = storage[GitHubInstallationTokenCacheKey.self] { return existing }
        let created = GitHubInstallationTokenCache()
        storage[GitHubInstallationTokenCacheKey.self] = created
        return created
    }
}
