// Tests/CoreTests/StreamedDigestTests.swift
//
// Streamed digest parity (#1160): hashing a file in chunks gives the same
// digest as hashing it in memory. Moved out of HashingTests.swift so that
// each file holds the type it is named for.

import Foundation
import Testing

@testable import Core

@Suite struct StreamedDigestTests {
    /// The claim-path version fingerprint must be byte-identical whether the
    /// zip is hashed in-memory (historical) or streamed — versions carry
    /// runner download caches across deploys.
    @Test func streamedDigestMatchesInMemoryConcatenation() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-stream-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Big enough to span multiple 1 MiB chunks.
        let bytes = Data((0..<2_500_000).map { UInt8($0 % 251) })
        try bytes.write(to: tmp)

        let prefix = Data("manifest|zip=".utf8)
        let streamed = sha256HexDigest(prefix: prefix, contentsOfFile: tmp.path)
        let inMemory = sha256HexDigest(prefix + bytes)
        #expect(streamed == inMemory)
    }

    @Test func streamedDigestReturnsNilForMissingFile() {
        let digest = sha256HexDigest(
            prefix: Data("x".utf8), contentsOfFile: "/nonexistent/\(UUID().uuidString)")
        #expect(digest == nil)
    }
}
