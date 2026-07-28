// Tests/APITests/AssignmentVersionBlobStoreTests.swift
//
// The content-addressed blob store behind assignment version snapshots
// (docs/assignment-versioning.md): identical bytes collapse to one blob,
// hashes are validated before they reach the filesystem, and writes land
// atomically so a concurrent reader never sees a partial blob.

import Core
import Foundation
import Testing

@testable import APIServer

// final class so deinit can remove the per-test temp directory.
@Suite final class AssignmentVersionBlobStoreTests {

    private let root: URL
    private let store: AssignmentVersionBlobStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-blobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AssignmentVersionBlobStore(testSetupsDirectory: root.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Round trip

    @Test func putThenReadReturnsTheSameBytes() throws {
        let payload = Data("print('hello')\n".utf8)
        let hash = try store.put(payload)

        #expect(hash == sha256HexDigest(payload))
        #expect(store.exists(hash))
        #expect(try store.read(hash) == payload)
    }

    @Test func putFileStreamsAndReturnsTheContentHash() throws {
        let source = root.appendingPathComponent("dataset.csv")
        let payload = Data("id,value\n1,42\n".utf8)
        try payload.write(to: source)

        let hash = try store.putFile(at: source.path)

        #expect(hash == sha256HexDigest(payload))
        #expect(try store.read(hash) == payload)
    }

    /// The whole point of content addressing: the same bytes stored twice
    /// occupy one blob, so an untouched dataset costs nothing across a long
    /// authoring session.
    @Test func identicalContentIsStoredOnce() throws {
        let payload = Data(repeating: 0xAB, count: 4096)
        let first = try store.put(payload)
        let second = try store.put(payload)

        #expect(first == second)
        let path = try store.path(for: first)
        let shard = (path as NSString).deletingLastPathComponent
        let entries = try FileManager.default.contentsOfDirectory(atPath: shard)
        #expect(entries == [first])
    }

    @Test func differentContentProducesDifferentBlobs() throws {
        let a = try store.put(Data("a".utf8))
        let b = try store.put(Data("b".utf8))
        #expect(a != b)
        #expect(try store.read(a) == Data("a".utf8))
        #expect(try store.read(b) == Data("b".utf8))
    }

    // MARK: - Hash validation

    /// Blob paths are built from a database column. A row carrying traversal
    /// components must not walk out of the blob directory — the shape check is
    /// what stops it, so it is checked directly rather than trusted.
    @Test(arguments: [
        "../../../etc/passwd",
        "..",
        "",
        "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
        "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
        "abc123",
    ])
    func rejectsAnythingThatIsNotASha256Digest(_ candidate: String) throws {
        #expect(!AssignmentVersionBlobStore.isValidHash(candidate))
        #expect(throws: AssignmentVersionBlobError.self) { try store.path(for: candidate) }
        #expect(!store.exists(candidate))
    }

    @Test func acceptsALowercaseSha256Digest() throws {
        let hash = sha256HexDigest(Data("x".utf8))
        #expect(AssignmentVersionBlobStore.isValidHash(hash))
        #expect(try store.path(for: hash).hasSuffix("/\(hash.prefix(2))/\(hash)"))
    }

    // MARK: - Reads of absent blobs

    @Test func readingAnUnstoredBlobThrowsNotFound() throws {
        let hash = sha256HexDigest(Data("never stored".utf8))
        #expect(throws: AssignmentVersionBlobError.self) { try store.read(hash) }
    }

    @Test func materializeCopiesTheBlobToTheRequestedPath() throws {
        let payload = Data("solution\n".utf8)
        let hash = try store.put(payload)
        let destination = root.appendingPathComponent("nested/dir/solution.py")

        try store.materialize(hash, to: destination)

        #expect(FileManager.default.contents(atPath: destination.path) == payload)
    }

    /// Restoring over an existing working directory must overwrite, not fail —
    /// a rebuild repopulates paths that already hold the current content.
    @Test func materializeOverwritesAnExistingFile() throws {
        let destination = root.appendingPathComponent("overwrite.txt")
        try Data("old".utf8).write(to: destination)
        let hash = try store.put(Data("new".utf8))

        try store.materialize(hash, to: destination)

        #expect(FileManager.default.contents(atPath: destination.path) == Data("new".utf8))
    }

    @Test func materializingAnUnstoredBlobThrows() throws {
        let hash = sha256HexDigest(Data("absent".utf8))
        #expect(throws: AssignmentVersionBlobError.self) {
            try store.materialize(hash, to: root.appendingPathComponent("out"))
        }
    }

    // MARK: - Concurrency

    /// Concurrent snapshots of the same unchanged dataset race on the identical
    /// blob routinely. The temp-file-plus-rename write means every writer
    /// succeeds and the final bytes are correct.
    @Test func concurrentWritesOfTheSameBlobAllSucceed() async throws {
        let payload = Data(repeating: 0x5A, count: 64 * 1024)
        // Captured as a local so the tasks don't reach through `self` (a class
        // suite instance, not Sendable) to get at it.
        let store = self.store
        let hashes = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<12 {
                group.addTask { try? store.put(payload) }
            }
            var seen: [String] = []
            for await hash in group { if let hash { seen.append(hash) } }
            return seen
        }

        #expect(hashes.count == 12)
        #expect(Set(hashes).count == 1)
        #expect(try store.read(sha256HexDigest(payload)) == payload)
    }
}
