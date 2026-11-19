// Tests/CoreTests/BundledDescriptionToleranceTests.swift
//
// A bundled dataset version whose description this server cannot read (a
// newer envelope) still imports, with no description, as the version row
// reads it (docs/dataset-kinds-plan.md §5). The import recomputes the facts
// from the bytes, so only the prose is lost.

import Foundation
import Testing

@testable import Core

@Suite struct BundledDescriptionToleranceTests {

    @Test func aNewerDescriptionReadsAsNone() throws {
        let json =
            #"{"version":1,"filename":"f.ndjson","sha256":"x","sizeBytes":1,"rowCount":1,"columns":[],"#
            + #""summary":{"descriptionVersion":2,"format":"fhirNdjson","fhirNdjson":{}}}"#
        let version = try JSONDecoder().decode(BundledDatasetVersion.self, from: Data(json.utf8))
        #expect(version.datasetDescription == nil)
        #expect(version.filename == "f.ndjson")
    }

    @Test func aCSVVersionEncodesNoSummary() throws {
        let version = BundledDatasetVersion(
            version: 1, filename: "a.csv", sha256: "x", sizeBytes: 1, rowCount: 1, columns: [], note: nil)
        let text = try #require(String(data: ManifestCodec.stableEncoder.encode(version), encoding: .utf8))
        #expect(!text.contains("summary"))
    }
}
