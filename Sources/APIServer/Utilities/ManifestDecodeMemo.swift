// APIServer/Utilities/ManifestDecodeMemo.swift
//
// A process-wide memo of decoded manifests (2026-11 performance audit).
//
// `TestProperties` is a large nested Codable: suites, pattern families with
// their case tables, sections, datasets and expressions. One request often
// decodes the same `test_setups.manifest` text several times (the route, the
// gates it calls, the page model), and the runner claim path decodes the
// queue head's manifest on every poll. The text changes only when an author
// edits the assignment, so the decoded value is memoized here.
//
// The key is the exact manifest bytes, so no invalidation is needed: an edit
// in any process changes the bytes, and the next lookup misses. That makes
// the memo correct across the blue-green processes without coordination.
// `TestProperties` is a value type, so a caller that mutates its copy cannot
// change what the memo hands the next caller.

import Core
import Foundation
import Synchronization

/// Decoded manifests keyed by their exact JSON bytes.
final class ManifestDecodeMemo: Sendable {
    static let shared = ManifestDecodeMemo()

    /// Distinct manifests kept before the memo starts again. A deployment's
    /// live assignments fit well inside it; past it, the memo is cleared
    /// wholesale, as `ZipEntryListCache` is, rather than tracking recency.
    static let capacity = 256

    /// A manifest larger than this is decoded every time, so one outsized
    /// manifest cannot hold a large share of memory.
    static let maximumMemoizedBytes = 512 * 1024

    /// The manifest bytes kept in all. Past it, the memo is cleared, as it is
    /// past `capacity`.
    static let maximumTotalBytes = 32 * 1024 * 1024

    private struct State {
        var entries: [Data: TestProperties] = [:]
        var totalBytes = 0
    }

    private let state = Mutex(State())

    /// The manifest that `data` decodes to, or nil when it does not decode.
    /// A failed decode is not memoized, so the nil answer is recomputed each
    /// time, exactly as a direct decode would be.
    func manifest(decoding data: Data) -> TestProperties? {
        guard data.count <= Self.maximumMemoizedBytes else { return Self.decode(data) }
        if let memoized = state.withLock({ $0.entries[data] }) { return memoized }
        // Decode outside the lock: two callers that miss at once both decode,
        // and both store the same value.
        guard let decoded = Self.decode(data) else { return nil }
        state.withLock { state in
            guard state.entries[data] == nil else { return }
            if state.entries.count >= Self.capacity || state.totalBytes + data.count > Self.maximumTotalBytes {
                state.entries.removeAll(keepingCapacity: true)
                state.totalBytes = 0
            }
            state.entries[data] = decoded
            state.totalBytes += data.count
        }
        return decoded
    }

    /// Number of memoized manifests, for tests.
    var count: Int { state.withLock { $0.entries.count } }

    /// True when nothing is memoized, for tests.
    var isEmpty: Bool { state.withLock { $0.entries.isEmpty } }

    private static func decode(_ data: Data) -> TestProperties? {
        try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
    }
}
