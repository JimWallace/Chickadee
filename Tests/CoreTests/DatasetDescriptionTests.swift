// Tests/CoreTests/DatasetDescriptionTests.swift
//
// The stored description of a dataset version (docs/dataset-kinds-plan.md
// §5): an envelope that names its version and its format. It reads the bare
// FHIR summary written before the envelope, and refuses a version or a
// format it cannot read, which every reader then treats as "no description".

import Foundation
import Testing

@testable import Core

@Suite struct DatasetDescriptionTests {

    private static let summary = FHIRDatasetSummary(
        fhirVersion: FHIRDatasetSummary.readAsVersion, resourceCount: 1, patientCount: 1,
        resourceTypes: [.init(resourceType: "Patient", count: 1, description: "Arrivals")], codes: [],
        omittedCodeCount: 0, danglingPatientReferences: 0)

    private func encoded(_ value: some Encodable) throws -> String {
        try #require(String(data: ManifestCodec.stableEncoder.encode(value), encoding: .utf8))
    }

    @Test func theEnvelopeNamesItsVersionAndFormatAndRoundTrips() throws {
        let description = DatasetDescription.fhirNdjson(Self.summary)
        let text = try encoded(description)
        #expect(text.hasPrefix(#"{"descriptionVersion":1,"fhirNdjson":{"#))
        #expect(text.contains(#""format":"fhirNdjson""#))
        #expect(try JSONDecoder().decode(DatasetDescription.self, from: Data(text.utf8)) == description)
        #expect(description.format == .fhirNdjson)
    }

    @Test func aBareSummaryWrittenBeforeTheEnvelopeReadsAsFHIR() throws {
        let bare = try encoded(Self.summary)
        let read = try JSONDecoder().decode(DatasetDescription.self, from: Data(bare.utf8))
        #expect(read == .fhirNdjson(Self.summary))
    }

    @Test(
        "A version or a payload this server cannot read is refused",
        arguments: [
            #"{"descriptionVersion":2,"format":"fhirNdjson","fhirNdjson":{}}"#,
            #"{"descriptionVersion":1,"format":"jsonRecords"}"#,
            #"{"descriptionVersion":1,"format":"csv"}"#,
        ])
    func refused(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DatasetDescription.self, from: Data(json.utf8))
        }
    }

    /// A bundle written before the envelope carries a bare summary under
    /// `summary`; it reads as the same description.
    @Test func aBundledVersionReadsBothForms() throws {
        let bare = try encoded(Self.summary)
        let json =
            #"{"version":1,"filename":"f.ndjson","sha256":"x","sizeBytes":1,"rowCount":1,"columns":[],"#
            + #""summary":"# + bare + "}"
        let version = try JSONDecoder().decode(BundledDatasetVersion.self, from: Data(json.utf8))
        #expect(version.summary == Self.summary)
        let reencoded = try encoded(version)
        #expect(reencoded.contains(#""summary":{"descriptionVersion":1"#))
        #expect(try JSONDecoder().decode(BundledDatasetVersion.self, from: Data(reencoded.utf8)) == version)
    }
}
