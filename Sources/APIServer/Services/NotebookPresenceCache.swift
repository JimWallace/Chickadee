// APIServer/Services/NotebookPresenceCache.swift
//
// Caches the "does this test setup zip contain a notebook?" answer for the
// student dashboard.  Answering it fresh shells out to `/usr/bin/unzip`
// (`listZipEntries`) under the global zip process lock — one subprocess
// spawn per assignment row per page view, with concurrent dashboard loads
// serializing behind one another on the lock.  The answer only changes when
// the zip bytes change, so it is cached keyed by the zip's modification
// date + size; every zip mutation path repacks the archive in place, which
// refreshes the mtime and invalidates the entry.

import Foundation
import Vapor

actor NotebookPresenceCache {
    private struct CachedAnswer {
        let zipModified: Date
        let zipSize: UInt64
        let hasNotebook: Bool
    }

    /// Safety valve, not a tuning knob: entries are tiny and keyed by setup
    /// zip path, so the dictionary grows with the number of test setups ever
    /// rendered.  Reset wholesale in the unlikely event it grows past this.
    private static let maxEntries = 4096

    private var answers: [String: CachedAnswer] = [:]

    /// True when the zip at `zipPath` contains at least one `.ipynb` entry.
    /// Returns false when the zip is missing or unreadable, matching
    /// `listZipEntries`' empty-list behaviour.
    func zipContainsNotebook(zipPath: String) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: zipPath),
            let zipModified = attributes[.modificationDate] as? Date
        else { return false }
        let zipSize = (attributes[.size] as? UInt64) ?? 0

        if let cached = answers[zipPath],
            cached.zipModified == zipModified,
            cached.zipSize == zipSize
        {
            return cached.hasNotebook
        }

        let hasNotebook = listZipEntries(zipPath: zipPath).contains { $0.hasSuffix(".ipynb") }
        if answers.count >= Self.maxEntries { answers.removeAll() }
        answers[zipPath] = CachedAnswer(
            zipModified: zipModified,
            zipSize: zipSize,
            hasNotebook: hasNotebook
        )
        return hasNotebook
    }
}

struct NotebookPresenceCacheKey: StorageKey {
    typealias Value = NotebookPresenceCache
}

extension Application {
    var notebookPresenceCache: NotebookPresenceCache {
        get {
            if let existing = storage[NotebookPresenceCacheKey.self] {
                return existing
            }
            let created = NotebookPresenceCache()
            storage[NotebookPresenceCacheKey.self] = created
            return created
        }
        set { storage[NotebookPresenceCacheKey.self] = newValue }
    }
}
