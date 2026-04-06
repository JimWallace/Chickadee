// Worker/TestSetupCache.swift

import Foundation

/// LRU cache of prepared (unzipped) test setup directories.
///
/// On a cache miss the `populate` closure is invoked exactly once per
/// `testSetupID`.  Concurrent `acquire` calls for the same key await the
/// in-flight population task rather than each downloading a separate copy.
///
/// On a cache hit the cached directory is **copied** into a fresh scratch
/// location that the caller owns and is responsible for deleting.
///
/// Cache entries are stored at `<cacheRoot>/<testSetupID>/prepared/`.
/// The default root is `/tmp/chickadee-runner-cache` (overridable via
/// `--test-setup-cache-dir` or `RUNNER_TEST_SETUP_CACHE_DIR`).
actor TestSetupCache {

    static let defaultMaxEntries = 16
    static let defaultCacheRoot  = URL(fileURLWithPath: "/tmp/chickadee-runner-cache")

    private let cacheRoot:  URL
    private let maxEntries: Int

    /// LRU order — index 0 is least-recently-used, last is most-recently-used.
    private var lruKeys: [String] = []

    /// In-progress population tasks, keyed by testSetupID.
    private var inProgress: [String: Task<URL, Error>] = [:]

    init(
        cacheRoot:  URL = TestSetupCache.defaultCacheRoot,
        maxEntries: Int = TestSetupCache.defaultMaxEntries
    ) {
        self.cacheRoot  = cacheRoot
        self.maxEntries = maxEntries
    }

    // MARK: - Public interface

    /// Returns a URL to a fresh, job-exclusive copy of the prepared test setup
    /// directory for `testSetupID`.
    ///
    /// The caller **owns** the returned directory and must delete it when the
    /// job finishes.
    ///
    /// - Parameters:
    ///   - testSetupID: Unique identifier used as the cache key.
    ///   - populate: Async closure that downloads and unzips the test setup
    ///               into a staging directory and returns that directory URL.
    ///               Called at most once per key; concurrent callers await the
    ///               same in-flight task.
    func acquire(
        testSetupID: String,
        populate: @Sendable () async throws -> URL
    ) async throws -> URL {

        let preparedDir = entryPreparedDir(for: testSetupID)

        // ── Cache hit ────────────────────────────────────────────────────────
        if FileManager.default.fileExists(atPath: preparedDir.path) {
            touchLRU(key: testSetupID)
            writeStructuredRunnerLog(event: "test_setup_cache_hit", fields: [
                "test_setup_id": testSetupID,
            ])
            return try copyToScratch(source: preparedDir, label: testSetupID)
        }

        // ── Already populating — await in-flight task ─────────────────────
        if let task = inProgress[testSetupID] {
            writeStructuredRunnerLog(event: "test_setup_cache_await_in_progress", fields: [
                "test_setup_id": testSetupID,
            ])
            let populated = try await task.value
            // Another caller may have already registered this key in lruKeys;
            // touchLRU is idempotent and safe to call from any code path.
            touchLRU(key: testSetupID)
            return try copyToScratch(source: populated, label: testSetupID)
        }

        // ── Cache miss — start population ────────────────────────────────────
        writeStructuredRunnerLog(event: "test_setup_cache_miss", fields: [
            "test_setup_id": testSetupID,
        ])

        let cacheRoot   = self.cacheRoot          // capture value type, not actor ref
        let populateTask = Task<URL, Error> {
            let stagingDir = try await populate()
            return try Self.commit(stagingDir: stagingDir, testSetupID: testSetupID, cacheRoot: cacheRoot)
        }
        inProgress[testSetupID] = populateTask

        do {
            let populated = try await populateTask.value
            inProgress.removeValue(forKey: testSetupID)
            // evictIfNeededForNew checks whether the key is already in lruKeys
            // (possible if a concurrent awaiter registered it first) so that we
            // never evict unnecessarily or double-register.
            evictIfNeededForNew(key: testSetupID)
            touchLRU(key: testSetupID)
            writeStructuredRunnerLog(event: "test_setup_cache_populated", fields: [
                "test_setup_id": testSetupID,
            ])
            return try copyToScratch(source: populated, label: testSetupID)
        } catch {
            inProgress.removeValue(forKey: testSetupID)
            cleanup(testSetupID: testSetupID, cacheRoot: cacheRoot)
            writeStructuredRunnerLog(event: "test_setup_cache_populate_failed", fields: [
                "test_setup_id":       testSetupID,
                "error_message_summary": String(describing: error),
            ])
            throw error
        }
    }

    // MARK: - LRU helpers

    /// Move `key` to the most-recently-used position (append to end).
    /// If `key` is not yet present it is added; this makes touchLRU safe to
    /// call from any code path (miss, in-progress, or hit).
    private func touchLRU(key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    /// Evict the least-recently-used entry if the cache is full, but only when
    /// `key` is genuinely new (not already tracked).  This prevents spurious
    /// evictions when a concurrent awaiter registers the key before the miss
    /// path finishes.
    private func evictIfNeededForNew(key: String) {
        guard !lruKeys.contains(key) else { return }
        while lruKeys.count >= maxEntries {
            let evicted = lruKeys.removeFirst()
            let evictedRoot = cacheRoot.appendingPathComponent(evicted)
            try? FileManager.default.removeItem(at: evictedRoot)
            writeStructuredRunnerLog(event: "test_setup_cache_evicted", fields: [
                "test_setup_id": evicted,
            ])
        }
    }

    // MARK: - Path helpers

    private func entryPreparedDir(for testSetupID: String) -> URL {
        cacheRoot
            .appendingPathComponent(testSetupID)
            .appendingPathComponent("prepared")
    }

    // MARK: - File operations

    /// Copy the prepared cache entry into a fresh temporary directory that
    /// the caller owns exclusively.
    private func copyToScratch(source: URL, label: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chickadee_ts_\(label)_\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Atomically move `stagingDir` into the cache at
    /// `<cacheRoot>/<testSetupID>/prepared/`.
    ///
    /// Uses a `<testSetupID>.tmp` intermediate to ensure the final entry is
    /// never partially visible.
    private static func commit(stagingDir: URL, testSetupID: String, cacheRoot: URL) throws -> URL {
        let tmpRoot     = cacheRoot.appendingPathComponent("\(testSetupID).tmp")
        let tmpPrepared = tmpRoot.appendingPathComponent("prepared")
        let entryRoot   = cacheRoot.appendingPathComponent(testSetupID)
        let preparedDir = entryRoot.appendingPathComponent("prepared")

        // Remove any leftover from a previous failed attempt.
        try? FileManager.default.removeItem(at: tmpRoot)

        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        // Move the caller-provided staging dir into .tmp/prepared.
        try FileManager.default.moveItem(at: stagingDir, to: tmpPrepared)

        // Replace any stale entry, then rename .tmp → final.
        try? FileManager.default.removeItem(at: entryRoot)
        try FileManager.default.moveItem(at: tmpRoot, to: entryRoot)

        return preparedDir
    }

    /// Remove any partial cache artefacts left by a failed population.
    private func cleanup(testSetupID: String, cacheRoot: URL) {
        let entryRoot = cacheRoot.appendingPathComponent(testSetupID)
        let tmpRoot   = cacheRoot.appendingPathComponent("\(testSetupID).tmp")
        try? FileManager.default.removeItem(at: entryRoot)
        try? FileManager.default.removeItem(at: tmpRoot)
    }
}
