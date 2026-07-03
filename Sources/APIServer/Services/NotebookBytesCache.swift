// APIServer/Services/NotebookBytesCache.swift
//
// Caches the normalized canonical-notebook bytes for a test setup (#1171).
// `notebookData(from:)` either reads the flat `.ipynb` or extracts the
// notebook from the setup zip via an `unzip` subprocess under the global zip
// process lock — #1166 moved that off the cooperative pool, but a class of
// students opening one assignment still paid one serialized subprocess per
// request. The extracted bytes only change when the backing file changes,
// and every mutation path rewrites the flat file / repacks the zip in place,
// refreshing the mtime — the same invalidation contract ZipEntryListCache
// relies on.
//
// Bounded by entry count AND total bytes: notebooks with embedded outputs
// run to MBs, so a pure entry cap could hold too much heap. Least-recently
// used entries are evicted first.

import Foundation
import NIOCore
import NIOPosix
import Vapor

actor NotebookBytesCache {
    static let defaultMaxEntries = 64
    static let defaultMaxTotalBytes = 128 * 1024 * 1024

    private struct CachedNotebook {
        let sourcePath: String
        let sourceModified: Date
        let sourceSize: UInt64
        let data: Data
    }

    private let maxEntries: Int
    private let maxTotalBytes: Int
    private let threadPool: NIOThreadPool?
    private let eventLoopGroup: EventLoopGroup?

    /// Keyed by the setup's zip path (stable per setup). LRU order tracked in
    /// `recentKeys` (most recent last).
    private var entries: [String: CachedNotebook] = [:]
    private var recentKeys: [String] = []
    private var totalBytes = 0
    private var inFlight: [String: Task<Result<Data, NotebookLookupError>, Never>] = [:]

    init(
        threadPool: NIOThreadPool? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        maxEntries: Int = NotebookBytesCache.defaultMaxEntries,
        maxTotalBytes: Int = NotebookBytesCache.defaultMaxTotalBytes
    ) {
        self.threadPool = threadPool
        self.eventLoopGroup = eventLoopGroup
        self.maxEntries = max(1, maxEntries)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    /// The setup's normalized canonical notebook, cached against the backing
    /// file's (path, size, mtime). Concurrent misses for the same setup share
    /// one resolution (single-flight), and the file read / zip extraction
    /// runs on the thread pool.
    func notebookData(for source: NotebookSourceRef) async throws(NotebookLookupError) -> Data {
        let key = source.zipPath

        if let cached = entries[key], validatorMatches(cached, source: source) {
            touch(key)
            return cached.data
        }

        let result: Result<Data, NotebookLookupError>
        if let pending = inFlight[key] {
            result = await pending.value
        } else {
            let threadPool = threadPool
            let eventLoop = eventLoopGroup?.next()
            let resolving = Task<Result<Data, NotebookLookupError>, Never> {
                do {
                    // Module-qualified: inside the actor, the bare name binds
                    // to this actor's own notebookData(for:) method.
                    if let threadPool, let eventLoop {
                        return .success(
                            try await threadPool.runIfActive(eventLoop: eventLoop) {
                                try APIServer.notebookData(from: source)
                            }.get())
                    }
                    return .success(try APIServer.notebookData(from: source))
                } catch let error as NotebookLookupError {
                    return .failure(error)
                } catch {
                    return .failure(.notFound(setupID: source.setupID ?? "unknown"))
                }
            }
            inFlight[key] = resolving
            result = await resolving.value
            inFlight[key] = nil
            if case .success(let data) = result {
                store(key: key, source: source, data: data)
            }
        }

        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    // MARK: - Internals

    /// The file whose (size, mtime) governs freshness: the flat notebook when
    /// present (instructor saves rewrite it), else the setup zip (suite edits
    /// repack it).
    private static func backingPath(for source: NotebookSourceRef) -> String {
        if let path = source.notebookPath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        return source.zipPath
    }

    private func validatorMatches(_ cached: CachedNotebook, source: NotebookSourceRef) -> Bool {
        // The backing-file CHOICE must still be current: a setup cached from
        // its zip that later gains a flat notebook (an editor save on a
        // legacy setup) must miss, or the stale zip extraction would mask
        // the new flat file.
        guard Self.backingPath(for: source) == cached.sourcePath else { return false }
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: cached.sourcePath),
            let modified = attrs[.modificationDate] as? Date
        else { return false }
        let size = (attrs[.size] as? UInt64) ?? 0
        return modified == cached.sourceModified && size == cached.sourceSize
    }

    private func store(key: String, source: NotebookSourceRef, data: Data) {
        let path = Self.backingPath(for: source)
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attrs[.modificationDate] as? Date
        else { return }

        if let existing = entries[key] { totalBytes -= existing.data.count }
        entries[key] = CachedNotebook(
            sourcePath: path,
            sourceModified: modified,
            sourceSize: (attrs[.size] as? UInt64) ?? 0,
            data: data
        )
        totalBytes += data.count
        touch(key)
        evictIfNeeded()
    }

    private func touch(_ key: String) {
        if let index = recentKeys.firstIndex(of: key) {
            recentKeys.remove(at: index)
        }
        recentKeys.append(key)
    }

    private func evictIfNeeded() {
        while entries.count > maxEntries || totalBytes > maxTotalBytes,
            let oldest = recentKeys.first
        {
            recentKeys.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.data.count
            }
        }
    }
}

struct NotebookBytesCacheKey: StorageKey {
    typealias Value = NotebookBytesCache
}

extension Application {
    var notebookBytesCache: NotebookBytesCache {
        get {
            if let existing = storage[NotebookBytesCacheKey.self] { return existing }
            let created = NotebookBytesCache(
                threadPool: threadPool, eventLoopGroup: eventLoopGroup)
            storage[NotebookBytesCacheKey.self] = created
            return created
        }
        set { storage[NotebookBytesCacheKey.self] = newValue }
    }
}
