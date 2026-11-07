// Tests/APITests/Assignments/ManifestDecodeMemoTests.swift
//
// `ManifestDecodeMemo` memoizes decoded manifests by their exact bytes. A
// memoized answer must be the answer a direct decode gives, a failed decode
// must stay a failure, and the memo must stay bounded.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct ManifestDecodeMemoTests {

    private static let manifest = TestProperties(
        requiredFiles: ["main.py"],
        testSuites: [TestSuiteEntry(tier: .pub, script: "pubtest_f_1.py", generatedBy: "f")],
        language: .python, languageDeclared: true)

    @Test func aMemoizedManifestEqualsADirectDecode() throws {
        let memo = ManifestDecodeMemo()
        let data = Data(try encodeManifest(Self.manifest).utf8)
        let direct = try ManifestCodec.decoder.decode(TestProperties.self, from: data)

        #expect(memo.manifest(decoding: data) == direct)
        #expect(memo.count == 1)
        // The second lookup is a hit and still the same value.
        #expect(memo.manifest(decoding: data) == direct)
        #expect(memo.count == 1)
    }

    @Test func aFailedDecodeIsNilAndIsNotMemoized() {
        let memo = ManifestDecodeMemo()
        #expect(memo.manifest(decoding: Data("not json".utf8)) == nil)
        #expect(memo.count == 0)
    }

    /// Different bytes are different keys, even when they decode to the
    /// same value, so an edit can never be answered from a stale entry.
    @Test func differentBytesAreDifferentEntries() throws {
        let memo = ManifestDecodeMemo()
        let stored = try encodeManifest(Self.manifest)
        let edited = TestProperties(
            requiredFiles: ["main.py", "helper.py"],
            testSuites: Self.manifest.testSuites,
            language: .python, languageDeclared: true)

        #expect(memo.manifest(decoding: Data(stored.utf8)) == Self.manifest)
        #expect(memo.manifest(decoding: Data(try encodeManifest(edited).utf8)) == edited)
        #expect(memo.count == 2)
    }

    /// A caller that changes its copy changes nothing another caller gets.
    @Test func aCallerMutatingItsCopyDoesNotChangeTheMemo() throws {
        let memo = ManifestDecodeMemo()
        let data = Data(try encodeManifest(Self.manifest).utf8)
        var first = try #require(memo.manifest(decoding: data))
        first.requiredFiles.append("mutated.py")

        #expect(memo.manifest(decoding: data) == Self.manifest)
    }

    @Test func theMemoStaysWithinItsCapacity() throws {
        let memo = ManifestDecodeMemo()
        for index in 0...ManifestDecodeMemo.capacity {
            let manifest = TestProperties(requiredFiles: ["file\(index).py"], language: .python)
            _ = memo.manifest(decoding: Data(try encodeManifest(manifest).utf8))
        }
        #expect(memo.count <= ManifestDecodeMemo.capacity)
    }
}
