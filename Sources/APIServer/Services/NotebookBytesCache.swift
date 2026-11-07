// APIServer/Services/NotebookBytesCache.swift
//
// Caches the normalized canonical-notebook bytes for a test setup (#1171).
// `notebookData(from:)` either reads the flat `.ipynb` or extracts the
// notebook from the setup zip via an `unzip` subprocess. Without the cache,
// a class of students opening one assignment paid one subprocess per
// request. The extracted bytes only change when the backing file changes,
// and every mutation path rewrites the flat file / repacks the zip in place,
// refreshing the mtime — the same invalidation contract ZipEntryListCache
// relies on.
//
// Bounded by entry count AND total bytes: notebooks with embedded outputs
// run to MBs, so a pure entry cap could hold too much heap. Least-recently
// used entries are evicted first.
//
// A setup with no notebook at all (an upload-only or hand-written suite) is
// remembered too, apart from the notebooks, so the result-ingest path does not
// list its zip on every result. Only a miss the zip's bytes decide is kept:
// see `NotebookResolution.absent`.

import Foundation
import Vapor

actor NotebookBytesCache {
    static let defaultMaxEntries = 64
    static let defaultMaxTotalBytes = 128 * 1024 * 1024

    /// Safety valve for remembered misses, as in `ZipEntryListCache`: they
    /// are small, so past this many the map is dropped wholesale.
    static let maxAbsentEntries = 4096

    private struct CachedNotebook {
        let sourcePath: String
        let sourceModified: Date
        let sourceSize: UInt64
        let data: Data
        /// The contribution slots `data` declares, once something has asked.
        var slotCount: Int?
    }

    /// A setup whose zip holds no notebook, against the inputs that decide it:
    /// the zip's (size, mtime) and the manifest's starter name.
    private struct AbsentNotebook {
        let zipModified: Date
        let zipSize: UInt64
        let starterNotebook: String?
    }

    private let maxEntries: Int
    private let maxTotalBytes: Int

    /// Keyed by the setup's zip path (stable per setup). LRU order tracked in
    /// `recentKeys` (most recent last).
    private var entries: [String: CachedNotebook] = [:]
    private var recentKeys: [String] = []
    private var totalBytes = 0
    private var inFlight: [String: Task<NotebookResolution, Never>] = [:]
    /// Kept apart from `entries`, so a remembered miss never evicts a notebook.
    private var absentByKey: [String: AbsentNotebook] = [:]

    init(
        maxEntries: Int = NotebookBytesCache.defaultMaxEntries,
        maxTotalBytes: Int = NotebookBytesCache.defaultMaxTotalBytes
    ) {
        self.maxEntries = max(1, maxEntries)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    /// The setup's normalized canonical notebook, cached against the backing
    /// file's (path, size, mtime). Concurrent misses for the same setup share
    /// one resolution (single-flight).
    func notebookData(for source: NotebookSourceRef) async throws(NotebookLookupError) -> Data {
        let key = source.zipPath

        if let cached = entries[key], validatorMatches(cached, source: source) {
            touch(key)
            return cached.data
        }
        if let absent = absentByKey[key], absentMatches(absent, source: source) {
            throw NotebookLookupError.notFound(setupID: source.setupID ?? "unknown")
        }

        let resolution: NotebookResolution
        if let pending = inFlight[key] {
            resolution = await pending.value
        } else {
            // Stat the zip BEFORE resolving: a zip replaced meanwhile is then
            // remembered under its old stat, which no later lookup matches.
            let zipStat = Self.zipBackedStat(for: source)
            // The call suspends rather than blocks, so it needs no
            // thread-pool offload.
            let resolving = Task<NotebookResolution, Never> {
                await resolveNotebook(from: source)
            }
            inFlight[key] = resolving
            resolution = await resolving.value
            inFlight[key] = nil
            switch resolution {
            case .found(let data):
                absentByKey[key] = nil
                store(key: key, source: source, data: data)
            case .absent:
                if let zipStat { rememberAbsent(key: key, zipStat: zipStat, source: source) }
            case .unavailable:
                // An unreadable zip or a failed extraction may not repeat, so
                // the next lookup resolves again.
                break
            }
        }

        guard case .found(let data) = resolution else {
            throw NotebookLookupError.notFound(setupID: source.setupID ?? "unknown")
        }
        return data
    }

    /// How many contribution slots the setup's notebook declares
    /// (`NotebookContributionSlots.declaredSlotCount(inInstructorNotebook:)`),
    /// or 0 when it has no notebook. The count depends on the bytes alone, so
    /// it is kept on the cache entry that holds them and counted once for each
    /// version of the notebook, rather than parsed again on every result.
    func declaredContributionSlotCount(for source: NotebookSourceRef) async -> Int {
        guard let data = try? await notebookData(for: source) else { return 0 }
        let key = source.zipPath
        // No suspension between this check and the write, so no other lookup
        // can replace the entry in between.
        guard let cached = entries[key], cached.data == data else {
            return NotebookContributionSlots.declaredSlotCount(inInstructorNotebook: data)
        }
        if let count = cached.slotCount { return count }
        let count = NotebookContributionSlots.declaredSlotCount(inInstructorNotebook: data)
        entries[key]?.slotCount = count
        return count
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

    /// The zip's (mtime, size) when the zip is the backing file, that is when
    /// there is no flat notebook. Nil otherwise, and then no miss is
    /// remembered: a flat file that exists but gave no notebook leaves the
    /// answer to the zip, which the flat file's stat does not follow.
    private static func zipBackedStat(for source: NotebookSourceRef) -> (modified: Date, size: UInt64)? {
        guard backingPath(for: source) == source.zipPath,
            let attrs = try? FileManager.default.attributesOfItem(atPath: source.zipPath),
            let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return (modified, (attrs[.size] as? UInt64) ?? 0)
    }

    private func absentMatches(_ absent: AbsentNotebook, source: NotebookSourceRef) -> Bool {
        guard absent.starterNotebook == source.starterNotebook,
            let zipStat = Self.zipBackedStat(for: source)
        else { return false }
        return zipStat.modified == absent.zipModified && zipStat.size == absent.zipSize
    }

    private func rememberAbsent(
        key: String, zipStat: (modified: Date, size: UInt64), source: NotebookSourceRef
    ) {
        if absentByKey.count >= Self.maxAbsentEntries { absentByKey.removeAll() }
        absentByKey[key] = AbsentNotebook(
            zipModified: zipStat.modified, zipSize: zipStat.size, starterNotebook: source.starterNotebook)
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
            data: data,
            slotCount: nil
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
        lazyStored(NotebookBytesCacheKey.self) {
            NotebookBytesCache()
        }
    }
}
