// Tests/APITests/ManifestStorageFormTests.swift
//
// Phase 4 of docs/manifest-format-v2.md: `encodeManifest` (the storage
// writer) writes v2 when the v2 form holds a manifest exactly and v1
// otherwise.  `encodeManifestV1` and `manifestTextAsV1` give the v1 form for
// each path that sends a manifest out of the server.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct ManifestStorageFormTests {

    private static let declared = TestProperties(
        requiredFiles: ["main.py"],
        testSuites: [TestSuiteEntry(tier: .pub, script: "pubtest_f_1.py", generatedBy: "f")],
        language: .python, languageDeclared: true)

    @Test func theStorageWriterWritesV2WhenItIsExact() throws {
        let stored = try encodeManifest(Self.declared)
        #expect(TestProperties.wireVersion(of: stored) == 2)
        #expect(decodeManifest(fromJSON: stored) == Self.declared)
    }

    /// A manifest that the v2 form cannot hold exactly is stored as v1.
    @Test func theStorageWriterKeepsV1WhenV2WouldLoseInformation() throws {
        let undeclaredWithLanguage = TestProperties(language: .python)
        let stored = try encodeManifest(undeclaredWithLanguage)
        #expect(TestProperties.wireVersion(of: stored) == 1)
        #expect(decodeManifest(fromJSON: stored) == undeclaredWithLanguage)
    }

    @Test func theV1WriterAlwaysWritesV1() throws {
        let text = try encodeManifestV1(Self.declared)
        #expect(TestProperties.wireVersion(of: text) == 1)
        #expect(decodeManifest(fromJSON: text) == Self.declared)
    }

    @Test func storedV1TextIsPassedOnByteForByte() {
        let v1 = #"{"timeLimitSeconds":10,"schemaVersion":1,"testSuites":[]}"#
        #expect(manifestTextAsV1(v1) == v1)
        #expect(manifestTextAsV1("not json") == "not json")
    }

    @Test func storedV2TextIsPassedOnAsV1() throws {
        let stored = try encodeManifest(Self.declared)
        let outward = manifestTextAsV1(stored)
        #expect(TestProperties.wireVersion(of: outward) == 1)
        #expect(outward == (try encodeManifestV1(Self.declared)))
    }
}
