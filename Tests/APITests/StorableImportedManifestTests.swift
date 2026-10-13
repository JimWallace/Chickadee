// Tests/APITests/StorableImportedManifestTests.swift
//
// Course-bundle import stores each setup's manifest text.  In phase 3 of
// docs/manifest-format-v2.md the server reads v2 but writes only v1, so a
// release that cannot read v2 stays a safe rollback target.
// `storableImportedManifest` keeps that true at the import door: v1 text is
// stored byte-for-byte, and v2 text is re-encoded as v1.

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

    @Test func v2TextIsStoredAsV1() throws {
        let v2 = #"""
            {"schemaVersion": 2, "language": "none",
             "files": [{"name": "main.py", "required": true}],
             "testSuites": [{"tier": "public", "script": "pubtest_f_1.py", "origin": {"family": "f"}}]}
            """#
        let stored = try storableImportedManifest(v2)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["requiredFiles"] as? [String] == ["main.py"])
        #expect(object["languageDeclared"] as? Bool == true)
        let suites = try #require(object["testSuites"] as? [[String: Any]])
        #expect(suites.first?["generatedBy"] as? String == "f")
        #expect(suites.first?["origin"] == nil)

        let reread = try #require(decodeManifest(fromJSON: stored))
        let original = try #require(decodeManifest(fromJSON: v2))
        #expect(reread == original)
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
