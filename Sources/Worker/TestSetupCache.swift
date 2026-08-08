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
    static let defaultCacheRoot = URL(fileURLWithPath: "/tmp/chickadee-runner-cache")

    private let cacheRoot: URL
    private let maxEntries: Int
    /// Where per-job scratch copies are made. Separate from `cacheRoot` because
    /// the two have different requirements: the cache only needs to be
    /// writable, while scratch is the working directory a test script runs in
    /// and so must also permit `exec` for a compiled language.
    private let scratchRoot: URL

    /// LRU order — index 0 is least-recently-used, last is most-recently-used.
    private var lruKeys: [String] = []

    /// One in-flight population: the unstructured task doing the download +
    /// commit, plus the continuation of every acquirer awaiting it. The task
    /// reports through `finishPopulation(testSetupID:result:)`, never via
    /// `task.value` — awaiting `Task.value` is not cancellation-responsive,
    /// and doing so from a job slot was the wait that made `daemon.run()`
    /// ignore cancellation on the artifact-download path (issue #1233,
    /// docs/ci-flakiness.md "what in daemon.run() ignores cancellation").
    private struct InFlightPopulation {
        var task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    }

    /// In-progress populations, keyed by testSetupID.
    private var inProgress: [String: InFlightPopulation] = [:]

    init(
        cacheRoot: URL = TestSetupCache.defaultCacheRoot,
        maxEntries: Int = TestSetupCache.defaultMaxEntries,
        scratchRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.cacheRoot = cacheRoot
        self.maxEntries = maxEntries
        self.scratchRoot = scratchRoot
        // Reconcile with what's already on disk: the LRU list used to be
        // memory-only, so entries surviving a daemon restart were never
        // tracked — they served hits but could never be evicted, growing
        // /tmp without bound across restarts and manifest edits (June 2026
        // audit, P2.4). Seed oldest-first so eviction order approximates LRU.
        lruKeys = Self.existingEntryKeysSortedByAge(cacheRoot: cacheRoot)
    }

    /// Keys of committed cache entries already on disk, oldest modification
    /// first. `.tmp` staging leftovers are ignored (and cleaned by the next
    /// populate of their key).
    private static func existingEntryKeysSortedByAge(cacheRoot: URL) -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return
            entries
            .filter { !$0.lastPathComponent.hasSuffix(".tmp") }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("prepared").path) }
            .sorted { lhs, rhs in
                let lhsDate =
                    (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhsDate =
                    (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lhsDate < rhsDate
            }
            .map(\.lastPathComponent)
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
    /// Result of an `acquire` call.  `directory` is the per-job scratch copy
    /// the caller owns; `didHit` distinguishes a fresh-from-disk hit (true)
    /// from a miss that triggered a populate or an await-in-progress (false),
    /// so the worker can persist the cache effectiveness alongside the
    /// existing `testSetupAcquireMs` stage timing.
    struct AcquireResult: Sendable {
        let directory: URL
        let didHit: Bool
    }

    nonisolated func acquire(
        testSetupID: String,
        populate: @escaping @Sendable () async throws -> URL
    ) async throws -> AcquireResult {
        // The scratch copy of a multi-MB prepared directory runs OUTSIDE actor
        // isolation so concurrent acquires for other setups don't serialize
        // behind file I/O (June 2026 audit, P2.4). The committed source dir is
        // immutable, so the only hazard is eviction racing the copy — rare
        // (needs 16+ distinct setups churning), and retried once below: with
        // the entry gone, the retry takes the populate path.
        do {
            let source = try await acquireSource(testSetupID: testSetupID, populate: populate)
            let scratch = try Self.copyToScratch(
                source: source.directory, label: testSetupID, scratchRoot: scratchRoot)
            return AcquireResult(directory: scratch, didHit: source.didHit)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let source = try await acquireSource(testSetupID: testSetupID, populate: populate)
            let scratch = try Self.copyToScratch(
                source: source.directory, label: testSetupID, scratchRoot: scratchRoot)
            return AcquireResult(directory: scratch, didHit: source.didHit)
        }
    }

    /// Actor-isolated bookkeeping half of `acquire`: returns the committed
    /// prepared directory (populating it if needed) without copying it.
    private func acquireSource(
        testSetupID: String,
        populate: @escaping @Sendable () async throws -> URL
    ) async throws -> AcquireResult {

        let preparedDir = entryPreparedDir(for: testSetupID)

        // ── Cache hit ────────────────────────────────────────────────────────
        if FileManager.default.fileExists(atPath: preparedDir.path) {
            touchLRU(key: testSetupID)
            writeStructuredRunnerLog(
                event: "test_setup_cache_hit",
                fields: [
                    "test_setup_id": testSetupID
                ])
            return AcquireResult(directory: preparedDir, didHit: true)
        }

        // ── Miss or in-flight — join the (possibly new) population ──────────
        // Joining an in-flight populate is a miss from the caller's
        // perspective — work was still being done on their behalf.
        let populated = try await awaitPopulation(testSetupID: testSetupID, populate: populate)
        return AcquireResult(directory: populated, didHit: false)
    }

    /// Awaits the population of `testSetupID`, starting it if none is in
    /// flight, and responds to the caller's task cancellation: a cancelled
    /// acquirer detaches promptly (throwing `CancellationError`) instead of
    /// riding out the download, and the population task itself is cancelled
    /// once its last waiter detaches — so a cancelled daemon stops its
    /// in-flight artifact downloads instead of ignoring cancellation
    /// (issue #1233).
    private func awaitPopulation(
        testSetupID: String,
        populate: @escaping @Sendable () async throws -> URL
    ) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs synchronously on the actor: the miss-check, task
                // start, and waiter registration form one isolation slice, so
                // `finishPopulation` cannot interleave between them.
                if Task.isCancelled {
                    // Cancellation delivered before registration: onCancel
                    // already ran against an unregistered waiter, so honour
                    // it here — nobody else will resume this continuation.
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var population = inProgress[testSetupID] {
                    writeStructuredRunnerLog(
                        event: "test_setup_cache_await_in_progress",
                        fields: [
                            "test_setup_id": testSetupID
                        ])
                    population.waiters[waiterID] = continuation
                    inProgress[testSetupID] = population
                } else {
                    writeStructuredRunnerLog(
                        event: "test_setup_cache_miss",
                        fields: [
                            "test_setup_id": testSetupID
                        ])
                    var population = InFlightPopulation(
                        task: makePopulationTask(testSetupID: testSetupID, populate: populate))
                    population.waiters[waiterID] = continuation
                    inProgress[testSetupID] = population
                }
            }
        } onCancel: {
            Task { await self.detachWaiter(testSetupID: testSetupID, waiterID: waiterID) }
        }
    }

    /// The unstructured population worker. Unstructured on purpose — it is
    /// shared by every concurrent acquirer of the key and must not be tied to
    /// any single caller's lifetime; it always reports through
    /// `finishPopulation`, which resumes whichever waiters remain.
    private func makePopulationTask(
        testSetupID: String,
        populate: @escaping @Sendable () async throws -> URL
    ) -> Task<Void, Never> {
        let cacheRoot = self.cacheRoot  // capture value type, not actor ref
        // `Task {}` inherits this actor's isolation, so `finishPopulation` is
        // a synchronous same-actor call here — no interleaving between the
        // result being ready and the waiters being resumed.
        return Task {
            let result: Result<URL, Error>
            do {
                let stagingDir = try await populate()
                result = .success(
                    try Self.commit(stagingDir: stagingDir, testSetupID: testSetupID, cacheRoot: cacheRoot))
            } catch {
                result = .failure(error)
            }
            self.finishPopulation(testSetupID: testSetupID, result: result)
        }
    }

    /// Terminal bookkeeping for a population: exactly once per key, whether
    /// it succeeded, failed, or was cancelled after its last waiter left.
    private func finishPopulation(testSetupID: String, result: Result<URL, Error>) {
        guard let population = inProgress.removeValue(forKey: testSetupID) else { return }
        switch result {
        case .success(let preparedDir):
            // evictIfNeededForNew checks whether the key is already in
            // lruKeys so that we never evict unnecessarily or double-register.
            evictIfNeededForNew(key: testSetupID)
            touchLRU(key: testSetupID)
            writeStructuredRunnerLog(
                event: "test_setup_cache_populated",
                fields: [
                    "test_setup_id": testSetupID
                ])
            for waiter in population.waiters.values {
                waiter.resume(returning: preparedDir)
            }
        case .failure(let error):
            cleanupPartialEntry(testSetupID: testSetupID)
            writeStructuredRunnerLog(
                event: "test_setup_cache_populate_failed",
                fields: [
                    "test_setup_id": testSetupID,
                    "error_message_summary": String(describing: error),
                ])
            for waiter in population.waiters.values {
                waiter.resume(throwing: error)
            }
        }
    }

    /// Removes a cancelled acquirer's continuation (resuming it with
    /// `CancellationError`) and, when it was the population's last waiter,
    /// cancels the population task itself: nobody wants the download any
    /// more, and a cancelled daemon must not keep transferring artifacts.
    /// A no-op when the population already finished — the waiter was then
    /// resumed with the real result before cancellation could land.
    private func detachWaiter(testSetupID: String, waiterID: UUID) {
        guard var population = inProgress[testSetupID],
            let continuation = population.waiters.removeValue(forKey: waiterID)
        else { return }
        inProgress[testSetupID] = population
        continuation.resume(throwing: CancellationError())
        if population.waiters.isEmpty {
            population.task.cancel()
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
            do {
                try FileManager.default.removeItem(at: evictedRoot)
                writeStructuredRunnerLog(
                    event: "test_setup_cache_evicted",
                    fields: [
                        "test_setup_id": evicted
                    ])
            } catch {
                writeStructuredRunnerLog(
                    event: "test_setup_cache_evict_failed",
                    fields: [
                        "test_setup_id": evicted,
                        "path": evictedRoot.path,
                        "error_type": String(describing: type(of: error)),
                        "error_message_summary": error.localizedDescription,
                    ])
            }
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
    /// the caller owns exclusively. Static (non-isolated) — see `acquire`.
    private static func copyToScratch(source: URL, label: String, scratchRoot: URL) throws -> URL {
        let dest =
            scratchRoot
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
        let tmpRoot = cacheRoot.appendingPathComponent("\(testSetupID).tmp")
        let tmpPrepared = tmpRoot.appendingPathComponent("prepared")
        let entryRoot = cacheRoot.appendingPathComponent(testSetupID)
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
    private func cleanupPartialEntry(testSetupID: String) {
        let entryRoot = cacheRoot.appendingPathComponent(testSetupID)
        let tmpRoot = cacheRoot.appendingPathComponent("\(testSetupID).tmp")
        try? FileManager.default.removeItem(at: entryRoot)
        try? FileManager.default.removeItem(at: tmpRoot)
    }
}
