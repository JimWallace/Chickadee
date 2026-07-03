// APIServer/Services/ZipEntryListCache.swift
//
// Caches the entry-name list of a test setup zip.  Listing a zip shells out to
// `/usr/bin/unzip` (`listZipEntries`) under the global zip process lock — one
// subprocess spawn per call, with concurrent callers serializing behind one
// another on the lock.  Several hot paths need that list per page view: the
// student dashboard's "does this setup contain a notebook?" check, and the
// per-visit support-file symlink pass on the notebook page (which runs even
// when the working copy is already seeded).  Caching the list keyed by the
// zip's modification date + size removes a redundant subprocess from every
// such visit.
//
// The list only changes when the zip bytes change, and every zip mutation path
// repacks the archive in place, which refreshes the mtime and invalidates the
// entry.  (Generalised from the former `NotebookPresenceCache`, which cached
// only the notebook-present boolean; that is now a derived query so there is
// one zip-listing cache rather than two near-identical ones.)

import Foundation
import NIOCore
import NIOPosix
import Vapor

actor ZipEntryListCache {
    private struct CachedEntries {
        let zipModified: Date
        let zipSize: UInt64
        let entries: [String]
    }

    /// Safety valve, not a tuning knob: entries are small and keyed by setup
    /// zip path, so the dictionary grows with the number of test setups ever
    /// listed.  Reset wholesale in the unlikely event it grows past this.
    private static let maxEntries = 4096

    /// Where the `unzip` subprocess actually runs (#1156). The old
    /// implementation ran `listZipEntries` inside the synchronous actor
    /// method, holding the actor's executor — a cooperative-pool thread —
    /// for the whole subprocess and serializing every cache caller behind a
    /// single miss. Nil (bare test instances) falls back to running the
    /// listing inline.
    private let threadPool: NIOThreadPool?
    private let eventLoopGroup: EventLoopGroup?

    /// One in-flight listing per zip path: concurrent misses on the same
    /// zip (a class opening one assignment post-deploy) share a single
    /// subprocess instead of queueing one each behind the global zip lock.
    private var inFlight: [String: Task<[String], Never>] = [:]

    private var cache: [String: CachedEntries] = [:]

    init(threadPool: NIOThreadPool? = nil, eventLoopGroup: EventLoopGroup? = nil) {
        self.threadPool = threadPool
        self.eventLoopGroup = eventLoopGroup
    }

    /// The zip's entry-name list (exactly what `listZipEntries` would return),
    /// cached by the zip's mtime + size.  Returns an empty list when the zip is
    /// missing or unreadable, matching `listZipEntries`' behaviour.
    func entries(zipPath: String) async -> [String] {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: zipPath),
            let zipModified = attributes[.modificationDate] as? Date
        else { return [] }
        let zipSize = (attributes[.size] as? UInt64) ?? 0

        if let cached = cache[zipPath],
            cached.zipModified == zipModified,
            cached.zipSize == zipSize
        {
            return cached.entries
        }

        if let pending = inFlight[zipPath] {
            return await pending.value
        }

        let threadPool = threadPool
        let eventLoop = eventLoopGroup?.next()
        let listing = Task<[String], Never> {
            if let threadPool, let eventLoop {
                return
                    (try? await threadPool.runIfActive(eventLoop: eventLoop) {
                        listZipEntries(zipPath: zipPath)
                    }.get()) ?? []
            }
            return listZipEntries(zipPath: zipPath)
        }
        inFlight[zipPath] = listing
        let entries = await listing.value
        inFlight[zipPath] = nil

        if cache.count >= Self.maxEntries { cache.removeAll() }
        cache[zipPath] = CachedEntries(
            zipModified: zipModified,
            zipSize: zipSize,
            entries: entries
        )
        return entries
    }

    /// True when the (cached) entry list contains at least one `.ipynb` entry.
    /// Returns false when the zip is missing or unreadable.
    func zipContainsNotebook(zipPath: String) async -> Bool {
        await entries(zipPath: zipPath).contains { $0.hasSuffix(".ipynb") }
    }
}

struct ZipEntryListCacheKey: StorageKey {
    typealias Value = ZipEntryListCache
}

extension Application {
    var zipEntryListCache: ZipEntryListCache {
        get {
            if let existing = storage[ZipEntryListCacheKey.self] {
                return existing
            }
            let created = ZipEntryListCache(
                threadPool: threadPool, eventLoopGroup: eventLoopGroup)
            storage[ZipEntryListCacheKey.self] = created
            return created
        }
        set { storage[ZipEntryListCacheKey.self] = newValue }
    }
}
