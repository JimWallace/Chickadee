import Foundation
import Testing

@testable import Core

struct HashingTests {

    /// SHA-256 reference vectors from FIPS 180-4 / common test corpora.
    /// If any of these fail, the digest output format has shifted —
    /// every consumer of `sha256HexDigest` (manifest cache keys, the
    /// v0.4.93 retest dedup column, X-Worker-Body-SHA256) must be
    /// reviewed before changing the format intentionally.
    @Test
    func emptyInputMatchesKnownDigest() {
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(sha256HexDigest(Data()) == expected)
    }

    @Test
    func abcInputMatchesKnownDigest() {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(sha256HexDigest("abc") == expected)
    }

    @Test
    func stringOverloadMatchesUTF8Data() {
        let s = "manifest contents — sortedKeys + ünïcode"
        #expect(sha256HexDigest(s) == sha256HexDigest(Data(s.utf8)))
    }

    @Test
    func outputIsAlways64LowercaseHexCharacters() {
        let inputs: [Data] = [
            Data(),
            Data([0]),
            Data(repeating: 0xff, count: 1024),
            Data("the quick brown fox".utf8),
        ]
        for input in inputs {
            let digest = sha256HexDigest(input)
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
        }
    }

    @Test
    func differentInputsProduceDifferentDigests() {
        let a = sha256HexDigest("foo")
        let b = sha256HexDigest("bar")
        #expect(a != b)
    }
}

// MARK: - Streamed digest parity (#1160)

@Suite struct StreamedDigestTests {
    /// The claim-path version fingerprint must be byte-identical whether the
    /// zip is hashed in-memory (historical) or streamed — versions carry
    /// runner download caches across deploys.
    @Test func streamedDigestMatchesInMemoryConcatenation() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-stream-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Big enough to span multiple 1 MiB chunks.
        var bytes = Data(count: 2_500_000)
        bytes.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8(index % 251) }
        }
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
