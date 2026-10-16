// APIServer/Services/NotebookGuideCache.swift
//
// Caches the student guide (`NotebookGuide`) per student and submission. A
// guide reads the solution, personalizes the starter (which can run the
// personalization evaluator) and unzips each hand-written script, and the
// editor asks for it on every load and again after each grading.
//
// The key holds everything a guide depends on that changes in the normal
// course of things: the student, the setup, the latest submission and whether
// it is graded yet, and the manifest. A change the key does not see (a
// notebook edit that leaves the manifest as it was, a new dataset or a reset
// personalization seed) is picked up when the entry expires.

import Foundation
import Vapor

actor NotebookGuideCache {
    struct Key: Hashable, Sendable {
        var userID: UUID
        var setupID: String
        /// The latest submission, or nil before the first one.
        var submissionID: String?
        var graded: Bool
        /// A digest of the manifest text, not the text, so a key stays small.
        var manifestDigest: String
    }

    static let defaultMaxEntries = 512
    static let defaultLifetime: TimeInterval = 120

    private struct Entry {
        let guide: NotebookGuide
        let storedAt: Date
    }

    private let maxEntries: Int
    private let lifetime: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var recentKeys: [Key] = []

    init(maxEntries: Int = defaultMaxEntries, lifetime: TimeInterval = defaultLifetime) {
        self.maxEntries = max(1, maxEntries)
        self.lifetime = lifetime
    }

    /// The cached guide for `key`, or the one `build` makes, which is then
    /// cached.
    func guide(
        for key: Key, now: Date = Date(), build: @Sendable () async throws -> NotebookGuide
    ) async rethrows -> NotebookGuide {
        if let entry = entries[key], now.timeIntervalSince(entry.storedAt) < lifetime {
            touch(key)
            return entry.guide
        }
        let guide = try await build()
        entries[key] = Entry(guide: guide, storedAt: now)
        touch(key)
        while entries.count > maxEntries, let oldest = recentKeys.first {
            recentKeys.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        return guide
    }

    private func touch(_ key: Key) {
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
    }
}

struct NotebookGuideCacheKey: StorageKey {
    typealias Value = NotebookGuideCache
}

extension Application {
    var notebookGuideCache: NotebookGuideCache {
        lazyStored(NotebookGuideCacheKey.self) {
            NotebookGuideCache()
        }
    }
}
