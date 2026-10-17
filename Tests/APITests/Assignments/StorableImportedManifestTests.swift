// Tests/APITests/Assignments/StorableImportedManifestTests.swift
//
// Course-bundle import stores each setup's manifest text.
// `storableImportedManifest` stores v1 text byte-for-byte and stores v2 text
// through `encodeManifest`, the one writer, so the database holds only what
// this release writes (docs/manifest-format-v2.md).

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct StorableImportedManifestTests {

    @Test func v1TextIsStoredByteForByte() throws {
        // Not in the stable encoder's key order, so a re-encode would show.
        let v1 = #"{"timeLimitSeconds":10,"schemaVersion":1,"testSuites":[],"requiredFiles":[]}"#
        #expect(try storableImportedManifest(v1) == v1)
    }

    @Test func v1TextThatDoesNotDecodeIsStoredAsItIs() throws {
        #expect(try storableImportedManifest("{}") == "{}")
        #expect(try storableImportedManifest("not json") == "not json")
    }

    /// Phase 4: the import stores a v2 manifest through `encodeManifest`,
    /// which writes v2 when that form holds the manifest exactly.
    @Test func v2TextIsStoredThroughTheWriter() throws {
        let v2 = #"""
            {"schemaVersion": 2, "language": "none",
             "files": [{"name": "main.py", "required": true}],
             "testSuites": [{"tier": "public", "script": "pubtest_f_1.py", "origin": {"family": "f"}}]}
            """#
        let stored = try storableImportedManifest(v2)
        #expect(TestProperties.wireVersion(of: stored) == 2)
        #expect(stored == (try encodeManifest(try #require(decodeManifest(fromJSON: v2)))))

        let reread = try #require(decodeManifest(fromJSON: stored))
        #expect(reread == (try #require(decodeManifest(fromJSON: v2))))
        #expect(reread.testSuites.map(\.origin) == [.family(id: "f")])
    }

    /// v2 text that does not decode would reach the database in a form that
    /// no release reads, so the import refuses it.
    @Test(arguments: [
        #"{"schemaVersion": 2, "language": "cobol"}"#,
        #"{"schemaVersion": 2, "files": [{"required": true}]}"#,
        #"{"schemaVersion": 2, "inputs": [{"name": "x", "value": 1, "expression": "seed"}]}"#,
    ])
    func v2TextThatDoesNotDecodeIsRefused(_ v2: String) {
        #expect(throws: (any Error).self) { try storableImportedManifest(v2) }
    }
}
